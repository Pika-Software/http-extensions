-- Libraries
local promise = promise
local gmad = gmad
local file = file
local http = http
local util = util

-- Variables
local os_time = os.time
local ipairs = ipairs
local select = select

local contentLifetime = CreateConVar( "http_content_lifetime", "72", FCVAR_ARCHIVE, "File lifetime in hours, if the file exists more than the specified number of hours, it will be deleted/replaced.", 0, 1 ):GetInt() * 60 * 60
cvars.AddChangeCallback( "http_content_lifetime", function( _, __, new )
    contentLifetime = ( tonumber( new ) or 1 ) * 60 * 60
end )

local contentPath = file.CreateDir( "gpm/" .. ( SERVER and "server" or "client" ) .. "/content/" )

function http.ClearCache( folder )
    if not folder then
        folder = contentPath
    else
        folder = folder .. "/"
    end

    local files, folders = file.Find( folder .. "*", "DATA" )
    for _, folderName in ipairs( folders ) do
        http.ClearCache( folder .. folderName )
    end

    for _, fileName in ipairs( files ) do
        if ( os_time() - file.Time( folder .. fileName, "DATA" ) ) > contentLifetime then
            file.Delete( folder .. fileName )
        end
    end
end

if CreateConVar( "http_content_autoremove", "1", FCVAR_ARCHIVE, "Allow files that were downloaded a long time ago to be deleted automatically.", 0, 1 ):GetBool() then http.ClearCache() end
cvars.AddChangeCallback( "http_content_autoremove", function( _, __, new )
    if new ~= "1" then return end
    http.ClearCache()
end )

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

        if file.Exists( filePath, "DATA" ) and ( os_time() - file.Time( filePath, "DATA" ) ) < contentLifetime then
            return {
                ["filePath"] = filePath,
                ["content"] = file.Read( filePath, "DATA" )
            }
        end

        if file.Exists( filePath, "DATA" ) then file.Delete( filePath ) end

        local ok, result = http.Fetch( url, headers, 120 ):SafeAwait()
        if not ok then return promise.Reject( result ) end

        local code = result.code
        if code ~= 200 then
            return promise.Reject( select( -1, http.GetStatusDescription( code ) ) )
        end

        local body = result.body
        local ok, err = file.AsyncWrite( filePath, body ):SafeAwait()
        if not ok then return promise.Reject( err ) end

        return {
            ["filePath"] = filePath,
            ["content"] = body
        }
    end )

end

http.DownloadContent = promise.Async( function( folder, url, extension, headers )
    if not file.IsDir( contentPath .. folder, "DATA" ) then file.CreateDir( contentPath .. folder ) end

    local fileName = string.gsub( string.lower( url ), "[/\\]+$", "" )
    local filePath = folder .. "/" .. util.MD5( fileName ) .. "." .. ( string.GetExtensionFromFilename( fileName ) or extension or "dat" )

    local ok, result = http.Download( url, filePath, headers ):SafeAwait()
    if ok then
        result.filePath = "data/" .. result.filePath
        return result
    end

    local ok, result = file.AsyncRead( filePath, "DATA" ):SafeAwait()
    if not ok then return promise.Reject( result ) end

    return {
        ["filePath"] = "data/" .. filePath,
        ["content"] = result.content
    }
end )

http.DownloadAudio = promise.Async( function( url, extension, headers )
    local ok, result = http.DownloadContent( "sounds/files", url, extension or "mp3", headers ):SafeAwait()
    if not ok then return promise.Reject( result ) end
    return result.filePath
end )

http.DownloadImage = promise.Async( function( url, extension, headers )
    local ok, result = http.DownloadContent( "images", url, extension or "png", headers ):SafeAwait()
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
        if file.Exists( filePath, "GAME" ) then return string.sub( filePath, 7, #filePath ) end

        if not file.IsDir( contentPath .. "sounds", "DATA" ) then
            file.CreateDir( contentPath .. "sounds" )
        end

        local cachePath = contentPath .. "sounds/" .. util.MD5( filePath ) .. ".gma.dat"
        if file.Exists( cachePath, "DATA" ) and ( os_time() - file.Time( filePath, "DATA" ) ) < contentLifetime then
            local ok, _ = game.MountGMA( cachePath )
            if ok then return string.sub( filePath, 7, #filePath ) end
        end

        if file.Exists( cachePath, "DATA" ) then file.Delete( cachePath ) end

        local ok, result = http.Fetch( url, headers, 120 ):SafeAwait()
        if not ok then return promise.Reject( result ) end

        local code = result.code
        if code ~= 200 then
            return promise.Reject( select( -1, http.GetStatusDescription( code ) ) )
        end

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