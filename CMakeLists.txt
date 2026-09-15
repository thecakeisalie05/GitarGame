cmake_minimum_required(VERSION 3.24)
project(GitarGame VERSION 0.1.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
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

set(GITARGAME_SOURCE "${CMAKE_SOURCE_DIR}/src/main_v3.cpp")
if (WIN32)
    set(GITARGAME_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
    set(GITARGAME_SOURCE "${GITARGAME_GENERATED_DIR}/main_v3.cpp")
    execute_process(
        COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
            -File "${CMAKE_SOURCE_DIR}/tools/prepare_alpha5.ps1"
            -InputPath "${CMAKE_SOURCE_DIR}/src/main_v3.cpp"
            -OutputPath "${GITARGAME_SOURCE}"
        RESULT_VARIABLE GITARGAME_PREPARE_RESULT
    )
    if (NOT GITARGAME_PREPARE_RESULT EQUAL 0)
        message(FATAL_ERROR "Failed to prepare the Windows alpha.5 source")
    endif()
endif()

add_executable(GitarGame
    "${GITARGAME_SOURCE}"
)

target_include_directories(GitarGame PRIVATE "${CMAKE_SOURCE_DIR}/src")
target_precompile_headers(GitarGame PRIVATE src/preinclude.h)
target_link_libraries(GitarGame PRIVATE raylib)

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
