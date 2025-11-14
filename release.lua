-- usage: xmake l release.lua
-- Add proxy: xmake g --proxy=ip:port

import("core.base.json")
import("core.base.global")
import("devel.git")
import("utils.archive")

function _get_current_commit_hash()
    return os.iorunv("git rev-parse --short HEAD"):trim()
end

function _get_current_tag()
    return os.iorunv("git describe --tags --abbrev=0"):trim()
end

-- @param llvm_archive string
function _get_require_libs(llvm_archive)
    git.clone("https://github.com/clice-io/clice.git", {treeless = true})
    os.cd("clice")

    os.mkdir("package")
    os.mkdir("package/backup")
    archive.extract(llvm_archive, "package/llvm")
    -- Use --project to specify the clice project and avoid xmake finding parent directory xmake.lua
    local argv = {
        "config",
        "--yes",
        "--clean",
        "--project=.",
        "--llvm=package/llvm",
    }
    if is_host("linux") then
        table.insert(argv, "--toolchain=clang-20")
    else
        table.insert(argv, "--toolchain=clang")
    end
    if is_host("macosx") then
        table.insert(argv, "--sdk=/opt/homebrew/opt/llvm@20")
    end
    os.vrunv(os.programfile(), argv)

    local unused_libs = {}
    local libs = table.join(os.files("build/.packages/**.lib"), os.files("build/.packages/**.a"))
    for _, lib in ipairs(libs) do
        printf("checking %s...", path.basename(lib))
        os.vmv(lib, "package/backup")
        -- Force xmake fetch package and avoid xmake using package cache
        os.vrunv(os.programfile(), argv)
        try
        {
            function ()
                os.vrunv(os.programfile(), {"--project=."})
                table.insert(unused_libs, path.basename(lib))
                cprint("${bright red} unused.")
            end,

            catch
            {
                function (errors)
                    cprint("${bright green} require!")
                    os.vmv(path.join("package/backup", path.filename(lib)), path.directory(lib))
                end
            }
        }
    end
    print("build %d libs, unused %d libs", #libs, #unused_libs)
    return unused_libs
end

-- @param llvm_archive string
-- @param unused_libs array
-- @return archive_file string
function _reduce_package_size(llvm_archive, unused_libs)
    os.tryrm("build")
    local workdir = "build/.pack"
    os.mkdir(workdir)
    archive.extract(llvm_archive, workdir)

    for _, lib in ipairs(unused_libs) do
        os.rm(path.join(workdir, format("lib/*%s*", lib)))
    end

    local opt = {}
    opt.recurse = true
    -- opt.compress = "best"
    opt.curdir = workdir

    local archive_dirs
    if is_host("windows") then
        archive_dirs = "*"
    elseif is_host("linux", "macosx") then
        -- workaround for tar
        archive_dirs = {}
        for _, dir in ipairs(os.dirs(path.join(opt.curdir, "*"))) do
            table.insert(archive_dirs, path.filename(dir))
        end
    end

    os.mkdir("build/pack")
    local archive_file = path.absolute(path.join("build/pack", path.filename(llvm_archive)))
    import("utils.archive").archive(archive_file, archive_dirs, opt)
    return archive_file
end

function main()
    local envs = {}
    if global.get("proxy") then
        envs.HTTPS_PROXY = global.get("proxy")
    end

    local tag = _get_current_tag()
    local current_commit = _get_current_commit_hash()

    print("current tag: ", tag)
    print("current commit: ", current_commit)

    local dir = path.join(os.scriptdir(), "artifacts", current_commit)
    os.mkdir(dir)

    local workflow = os.host()
    if is_host("macosx") then
        workflow = "macos"
    end
    -- Get latest workflow id
    local result = json.decode(os.iorunv(format("gh run list --json databaseId --limit 1 --workflow=%s.yml", workflow)))
    for _, json in pairs(result) do
        -- float -> int
        local run_id = format("%d", json["databaseId"])
        -- download all artifacts
        os.execv("gh", {"run", "download", run_id, "--dir", dir}, {envs = envs})
    end

    local origin_files = {}
    table.join2(origin_files, os.files(path.join(dir, "**.7z")))
    table.join2(origin_files, os.files(path.join(dir, "**.tar.xz")))

    local unused_libs
    for _, llvm_archive in ipairs(origin_files) do
        if llvm_archive:find("releasedbg") and llvm_archive:find("lto_n") then
            unused_libs = _get_require_libs(path.absolute(llvm_archive))
            break
        end
    end
    if not unused_libs then
        print("No unused libs?")
    end

    local files = {}
    for _, llvm_archive in ipairs(origin_files) do
        table.insert(files, _reduce_package_size(path.absolute(llvm_archive), unused_libs))
    end

    local binaries = {}
    -- greater than 2 Gib?
    for _, i in ipairs(files) do
        local file = io.open(i, "r")
        local size, error = file:size()
        -- github release limit 2 Gib
        if size > 2 * 1024 * 1024 * 1024 then
            print("%s > 2 Gib, skip", path.filename(i))
            print(file)
        else
            table.insert(binaries, i)
        end
    end

    print(binaries)
    -- clobber: overwrite
    for _, binary in ipairs(binaries) do
        os.execv("gh", {"release", "upload", tag, binary, "--clobber"}, {envs = envs})
    end
end
