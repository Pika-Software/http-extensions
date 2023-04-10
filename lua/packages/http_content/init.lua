-- Libraries
local promise = promise
local gmad = gpm.gmad
local fs = gpm.fs
local http = http
local util = util

-- Variables
local os_time = os.time
local ipairs = ipairs

local contentLifetime = CreateConVar( "http_content_lifetime", "24", FCVAR_ARCHIVE, " - file lifetime in hours, if the file exists more than the specified number of hours, it will be deleted/replaced.", 0, 1 ):GetInt() * 60 * 60
cvars.AddChangeCallback( "http_content_lifetime", function( _, __, new )
    contentLifetime = ( tonumber( new ) or 1 ) * 60 * 60
end, "gpm.http_content" )

local contentPath = "gpm/" .. ( SERVER and "server" or "client" ) .. "/content/"
fs.CreateDir( contentPath )

function http.ClearCache( folder )
    if not folder then
        folder = contentPath
    else
        folder = folder .. "/"
    end

    local files, folders = fs.Find( folder .. "*", "DATA" )
    for _, folderName in ipairs( folders ) do
        http.ClearCache( folder .. folderName )
    end

    for _, fileName in ipairs( files ) do
        if ( os_time() - fs.Time( folder .. fileName, "DATA" ) ) > contentLifetime then
            fs.Delete( folder .. fileName )
        end
    end
end

if CreateConVar( "http_content_autoremove", "1", FCVAR_ARCHIVE, " - allow files that were downloaded a long time ago to be deleted automatically.", 0, 1 ):GetBool() then http.ClearCache() end
cvars.AddChangeCallback( "http_content_autoremove", function( _, __, new )
    if new ~= "1" then return end
    http.ClearCache()
end, "gpm.http_content" )

do

    local allowedExtensions = { "txt", "dat", "json", "xml", "csv", "jpg", "jpeg", "png", "vtf", "vmt", "mp3", "wav", "ogg" }

    http.Download = promise.Async( function( url, filePath, headers )
        filePath = string.lower( filePath )

        local allowed, extension = false, string.GetExtensionFromFilename( filePath )
        for _, ext in ipairs( allowedExtensions ) do
            if ext ~= extension then continue end
            allowed = true
        end

        if not allowed then
            filePath = filePath .. ".dat"
        end

        filePath = contentPath .. filePath

        if fs.Exists( filePath, "DATA" ) and ( os_time() - fs.Time( filePath, "DATA" ) ) < contentLifetime then
            local ok, result = fs.AsyncRead( filePath, "DATA" ):SafeAwait()
            if ok then
                return {
                    ["filePath"] = filePath,
                    ["content"] = result
                }
            end
        end

        if fs.Exists( filePath, "DATA" ) then fs.Delete( filePath ) end

        local ok, result = http.Fetch( url, headers, 120 ):SafeAwait()
        if not ok then return promise.Reject( result ) end

        if result.code ~= 200 then return promise.Reject( "invalid response http code - " .. result.code ) end

        local ok, err = fs.AsyncWrite( filePath, result.body ):SafeAwait()
        if not ok then return promise.Reject( err ) end

        return {
            ["filePath"] = filePath,
            ["content"] = result.body
        }
    end )

end

http.DownloadContent = promise.Async( function( folder, url, headers )
    if not fs.IsDir( contentPath .. folder, "DATA" ) then fs.CreateDir( contentPath .. folder ) end

    local fileName = string.gsub( string.lower( url ), "[/\\]+$", "" )
    local filePath = folder .. "/" .. util.SHA1( fileName ) .. "." .. ( string.GetExtensionFromFilename( fileName ) or "dat" )

    local ok, result = http.Download( url, filePath, headers ):SafeAwait()
    if ok then
        result.filePath = "data/" .. result.filePath
        return result
    end

    local ok, content = fs.AsyncRead( filePath, "DATA" ):SafeAwait()
    if not ok then return promise.Reject( result ) end

    return {
        ["filePath"] = "data/" .. filePath,
        ["content"] = content
    }
end )

http.DownloadAudio = promise.Async( function( url, parameters, headers )
    local ok, result = http.DownloadContent( "sounds/files", url, headers ):SafeAwait()
    if not ok then return promise.Reject( result ) end
    return result.filePath
end )

http.DownloadImage = promise.Async( function( url, headers )
    local ok, result = http.DownloadContent( "images", url, headers ):SafeAwait()
    if not ok then return promise.Reject( result ) end
    return result.filePath
end )

do

    local Material = Material
    local materialCache = {}

    http.DownloadMaterial = promise.Async( function( url, parameters, headers )
        local ok, filePath = http.DownloadImage( url, headers ):SafeAwait()
        if not ok then return promise.Reject( filePath ) end

        local cacheName = filePath .. ";" .. ( parameters or "" )
        local cachedMaterial = materialCache[ cacheName ]
        if cachedMaterial then return cachedMaterial end

        local material = Material( filePath, parameters )
        if material:IsError() then return promise.Reject( "image cannot be converted to material" ) end
        materialCache[ cacheName ] = material

        return material
    end )

end

do

    local allowedExtensions = {
        ["wav"] = true,
        ["mp3"] = true,
        ["ogg"] = true
    }

    local allowedContentType = {
        ["audio/x-pn-wav"] = true,
        ["audio/x-wav"] = true,
        ["audio/wave"] = true,
        ["audio/mpeg"] = true,
        ["audio/wav"] = true,
        ["audio/ogg"] = true
    }

    http.DownloadSound = promise.Async( function( url, headers )
        local filePath = string.lower( url )

        local extension = string.GetExtensionFromFilename( filePath )
        if not allowedExtensions[ extension ] then return promise.Reject( "invalid file type" ) end
        if not extension then return promise.Reject( "invalid link" ) end

        local fileName = string.GetFileFromFilename( filePath )
        local filePath = "sound/gpm/content/" .. fileName
        if fs.Exists( filePath, "GAME" ) then return string.sub( filePath, 7, #filePath ) end

        if not fs.IsDir( contentPath .. "sounds", "DATA" ) then
            fs.CreateDir( contentPath .. "sounds" )
        end

        local cachePath = contentPath .. "sounds/" .. util.SHA1( filePath ) .. ".gma.dat"
        if fs.Exists( cachePath, "DATA" ) and ( os_time() - fs.Time( filePath, "DATA" ) ) < contentLifetime then
            local ok, _ = game.MountGMA( cachePath )
            if ok then return string.sub( filePath, 7, #filePath ) end
        end

        if fs.Exists( cachePath, "DATA" ) then fs.Delete( cachePath ) end

        local ok, result = http.Fetch( url, headers, 120 ):SafeAwait()
        if not ok then return promise.Reject( result ) end

        if result.code ~= 200 then return promise.Reject( "invalid response http code - " .. result.code ) end
        if not allowedContentType[ result.headers["Content-Type"] ] then return promise.Reject( "invalid file content" ) end

        local gma = gmad.Write( cachePath )
        if not gma then return promise.Reject( "unable to start recording" ) end

        gma:SetTitle( fileName )
        gma:AddFile( filePath, result.body )
        gma:Close()

        local ok, _ = game.MountGMA( "data/" .. cachePath )
        if ok then return string.sub( filePath, 7, #filePath ) end

        return promise.Reject( "assembly failed" )
    end )

end