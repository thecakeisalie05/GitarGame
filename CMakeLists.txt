cmake_minimum_required(VERSION 3.24)
project(GitarGame VERSION 0.1.6 LANGUAGES C CXX)

# GitHub's current Windows image ships CMake 4.x. libogg 1.3.5 predates the
# CMake 4 policy floor, so explicitly permit its older policy baseline while
# keeping GitarGame itself on modern CMake.
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)

# Keep third-party test/example trees out of the release build. GitarGame's own
# regression suite is enabled after dependencies have been populated.
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_GAMES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    raylib
    GIT_REPOSITORY https://github.com/raysan5/raylib.git
    GIT_TAG 5.5
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(raylib)

# Native Ogg Opus compatibility for Rock Band/YARG-style song packages.
# opusfile depends on libogg + libopus; OVERRIDE_FIND_PACKAGE lets its own
# find_package() calls resolve to these pinned FetchContent dependencies.
set(INSTALL_DOCS OFF CACHE BOOL "" FORCE)
set(INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_PACKAGE_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
    ogg
    GIT_REPOSITORY https://github.com/xiph/ogg.git
    GIT_TAG v1.3.5
    GIT_SHALLOW TRUE
    OVERRIDE_FIND_PACKAGE
)
FetchContent_MakeAvailable(ogg)

set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
    opus
    GIT_REPOSITORY https://github.com/xiph/opus.git
    GIT_TAG v1.5.2
    GIT_SHALLOW TRUE
    OVERRIDE_FIND_PACKAGE
)
FetchContent_MakeAvailable(opus)

set(OP_DISABLE_HTTP ON CACHE BOOL "" FORCE)
set(OP_DISABLE_EXAMPLES ON CACHE BOOL "" FORCE)
set(OP_DISABLE_DOCS ON CACHE BOOL "" FORCE)
FetchContent_Declare(
    opusfile
    GIT_REPOSITORY https://github.com/xiph/opusfile.git
    GIT_TAG v0.12
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(opusfile)

set(BUILD_TESTING ON CACHE BOOL "" FORCE)
enable_testing()

set(GITARGAME_SOURCE "${CMAKE_SOURCE_DIR}/src/main_v3.cpp")
if (WIN32)
    set(GITARGAME_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
    set(GITARGAME_SOURCE "${GITARGAME_GENERATED_DIR}/main_v3.cpp")
    execute_process(
        COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
            -File "${CMAKE_SOURCE_DIR}/tools/prepare_alpha9.ps1"
            -InputPath "${CMAKE_SOURCE_DIR}/src/main_v3.cpp"
            -OutputPath "${GITARGAME_SOURCE}"
        RESULT_VARIABLE GITARGAME_PREPARE_RESULT
    )
    if (NOT GITARGAME_PREPARE_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to prepare the Windows alpha.9 source")
    endif()
endif()

add_executable(GitarGame
    "${GITARGAME_SOURCE}"
)

target_include_directories(GitarGame PRIVATE "${CMAKE_SOURCE_DIR}/src")
target_precompile_headers(GitarGame PRIVATE src/preinclude.h)
# opusfile v0.12 exports the plain target name; newer revisions also provide a
# namespaced alias. Link the pinned release target directly for deterministic CI.
target_link_libraries(GitarGame PRIVATE raylib opusfile)

if (WIN32)
    target_compile_definitions(GitarGame PRIVATE WIN32_LEAN_AND_MEAN NOGDI NOUSER NOMINMAX _CRT_SECURE_NO_WARNINGS)
    target_link_libraries(GitarGame PRIVATE Xinput9_1_0 winmm dbghelp)
endif()

if (MSVC)
    target_compile_options(GitarGame PRIVATE /W4 /permissive- /Zi)
    target_link_options(GitarGame PRIVATE /DEBUG /OPT:REF /OPT:ICF)
else()
    target_compile_options(GitarGame PRIVATE -Wall -Wextra -Wpedantic)
endif()

set_target_properties(GitarGame PROPERTIES
    OUTPUT_NAME "GitarGame"
)

add_executable(GitarGameChartTests tests/chart_engine_tests.cpp)
target_include_directories(GitarGameChartTests PRIVATE "${CMAKE_SOURCE_DIR}/src")
if (MSVC)
    target_compile_options(GitarGameChartTests PRIVATE /W4 /permissive-)
else()
    target_compile_options(GitarGameChartTests PRIVATE -Wall -Wextra -Wpedantic)
endif()
add_test(NAME chart-compatibility COMMAND GitarGameChartTests)
