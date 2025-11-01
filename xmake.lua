set_policy("compatibility.version", "3.0")

add_requires("llvm", {
    system = false,
    configs = {
        mode = get_config("mode"),
        debug = is_mode("debug"),
        shared = is_mode("debug") and not is_plat("windows"),
    },
})

local sparse_checkout_list = {
    "cmake",
    "llvm",
    "clang",
    "clang-tools-extra",
}

-- TODO: If we need compiler-rt builtin-headers, then we need to enable them.
-- if is_mode("debug") then
--     table.insert(sparse_checkout_list, "runtimes")
--     table.insert(sparse_checkout_list, "compiler-rt")
-- end

package("llvm")
    add_urls("https://github.com/llvm/llvm-project.git", {alias = "git", includes = sparse_checkout_list})

    add_versions("git:21.1.4", "llvmorg-21.1.4")
    add_versions("git:20.1.5", "llvmorg-20.1.5")

    add_configs("mode", {description = "Build type", default = "releasedbg", type = "string", values = {"debug", "release", "releasedbg"}})

    if is_plat("windows", "mingw") then
        add_syslinks("version", "ntdll")
    end

    add_deps("cmake", "ninja", "python 3.x", {kind = "binary"})

    if is_host("windows") then
        set_policy("platform.longpaths", true)
    end

    on_install(function (package)
        if not package:config("shared") then
            package:add("defines", "CLANG_BUILD_STATIC")
        end

        io.replace("clang/CMakeLists.txt", "add_subdirectory(tools)",
            "add_llvm_external_project(clang-tools-extra extra)\nadd_clang_subdirectory(libclang)", {plain = true})

        local clang_tools = {
            "clang-apply-replacements",
            "clang-reorder-fields",
            -- "modularize",
            "clang-tidy",
            "clang-change-namespace",
            "clang-doc",
            "clang-include-fixer",
            "clang-move",
            "clang-query",
            "include-cleaner",
            -- "pp-trace",
            "tool-template",
        }
        for _, tool in ipairs(clang_tools) do
            io.replace(format("clang-tools-extra/%s/CMakeLists.txt", tool), "add_subdirectory(tool)", "", {plain = true})
        end
        io.replace("clang-tools-extra/CMakeLists.txt", "add_subdirectory(modularize)", "", {plain = true})
        io.replace("clang-tools-extra/CMakeLists.txt", "add_subdirectory(pp-trace)", "", {plain = true})

        local configs = {
            "-DLLVM_INCLUDE_DOCS=OFF",
            "-DLLVM_INCLUDE_TESTS=OFF",
            "-DLLVM_INCLUDE_EXAMPLES=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF",

            -- "-DCLANG_BUILD_TOOLS=OFF",
            -- "-DLLVM_INCLUDE_TOOLS=OFF",
            "-DLLVM_BUILD_TOOLS=OFF",
            "-DLLVM_BUILD_UTILS=OFF",
            "-DCLANG_ENABLE_CLANGD=OFF",

            "-DLLVM_ENABLE_ZLIB=OFF",
            "-DLLVM_ENABLE_ZSTD=OFF",
            "-DLLVM_ENABLE_LIBXML2=OFF",

            "-DLLVM_LINK_LLVM_DYLIB=OFF",
            "-DLLVM_ENABLE_RTTI=OFF",

            "-DLLVM_PARALLEL_LINK_JOBS=1",

            -- Build job and link job together will oom
            "-DCMAKE_JOB_POOL_LINK=console",

            "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra",

            -- Only build native target
            "-DLLVM_TARGETS_TO_BUILD=Native"
        }

        local build_type = {
            ["debug"] = "Debug",
            ["release"] = "Release",
            ["releasedbg"] = "RelWithDebInfo",
        }
        table.insert(configs, "-DCMAKE_BUILD_TYPE=" .. (build_type[package:config("mode")]))
        table.insert(configs, "-DBUILD_SHARED_LIBS=" .. (package:config("shared") and "ON" or "OFF"))
        table.insert(configs, "-DLLVM_ENABLE_LTO=" .. (package:config("lto") and "ON" or "OFF"))

        if package:config("mode") == "debug" then
            table.insert(configs, "-DLLVM_USE_SANITIZER=Address")
        end

        if package:is_plat("windows") then
            table.insert(configs, "-DCMAKE_C_COMPILER=clang-cl")
            table.insert(configs, "-DCMAKE_CXX_COMPILER=clang-cl")
        elseif package:is_plat("linux") then
            table.insert(configs, "-DLLVM_USE_LINKER=lld")
            -- table.insert(configs, "-DLLVM_USE_SPLIT_DWARF=ON")
        elseif package:is_plat("macosx") then
            table.insert(configs, "-DCMAKE_OSX_ARCHITECTURES=arm64")
            table.insert(configs, "-DCMAKE_LIBTOOL=/opt/homebrew/opt/llvm@20/bin/llvm-libtool-darwin")
            table.insert(configs, "-DLLVM_USE_LINKER=lld")
            table.insert(configs, "-DLLVM_ENABLE_LIBCXX=ON")
        end

        local opt = {}
        opt.target = {
            "LLVMSupport",
            "LLVMFrontendOpenMP",
            "clangAST",
            "clangASTMatchers",
            "clangBasic",
            "clangDependencyScanning",
            "clangDriver",
            "clangFormat",
            "clangFrontend",
            "clangIndex",
            "clangLex",
            "clangSema",
            "clangSerialization",
            "clangTooling",
            "clangToolingCore",
            "clangToolingInclusions",
            "clangToolingInclusionsStdlib",
            "clangToolingSyntax",
            "clangTidy",
            "clangTidyUtils",
        }

        os.cd("llvm")
        import("package.tools.cmake").install(package, configs, opt)

        if package:is_plat("windows") then
            for _, file in ipairs(os.files(package:installdir("bin/*"))) do
                if not file:endswith(".dll") then
                    os.rm(file)
                end
            end
        elseif package:is_plat("linux") then
            os.rm(package:installdir("bin/*"))
        end

        local clang_include_dir = "../clang/lib/Sema"
        local install_clang_include_dir = package:installdir("include/clang/Sema")
        os.vcp(path.join(clang_include_dir, "CoroutineStmtBuilder.h"), install_clang_include_dir)
        os.vcp(path.join(clang_include_dir, "TypeLocBuilder.h"), install_clang_include_dir)
        os.vcp(path.join(clang_include_dir, "TreeTransform.h"), install_clang_include_dir)

        local abi
        local format
        if package:is_plat("windows") then
            abi = "msvc"
            format = ".7z"
        elseif package:is_plat("linux") then
            abi = "gnu"
            format = ".tar.xz"
        elseif package:is_plat("macosx") then
            abi = "apple"
            format = ".tar.xz"
        end
        -- arch-plat-abi-mode
        local archive_name = table.concat({
            package:arch(),
            package:plat(),
            abi,
            package:config("mode"),
        }, "-")

        if package:config("lto") then
            archive_name = archive_name .. "-lto"
        end

        local archive_file = path.join(os.scriptdir(), "build/package", archive_name .. format)

        local opt = {}
        opt.recurse = true
        opt.compress = "best"
        opt.curdir = package:installdir()

        local archive_dirs
        if package:is_plat("windows") then
            archive_dirs = "*"
        elseif package:is_plat("linux", "macosx") then
            -- workaround for tar
            archive_dirs = {}
            for _, dir in ipairs(os.dirs(path.join(opt.curdir, "*"))) do
                table.insert(archive_dirs, path.filename(dir))
            end
        end
        import("utils.archive").archive(archive_file, archive_dirs, opt)

        local checksum = hash.sha256(archive_file)
        print(checksum)
    end)
