cmake_minimum_required(VERSION 3.24)
project(GitarGame VERSION 0.1.0 LANGUAGES CXX)

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

add_executable(GitarGame
    src/main.cpp
)

target_precompile_headers(GitarGame PRIVATE src/preinclude.h)
target_link_libraries(GitarGame PRIVATE raylib)

if (WIN32)
    target_compile_definitions(GitarGame PRIVATE WIN32_LEAN_AND_MEAN NOGDI NOUSER NOMINMAX _CRT_SECURE_NO_WARNINGS)
    target_link_libraries(GitarGame PRIVATE Xinput9_1_0 winmm)
endif()

if (MSVC)
    target_compile_options(GitarGame PRIVATE /W4 /permissive-)
else()
    target_compile_options(GitarGame PRIVATE -Wall -Wextra -Wpedantic)
endif()

set_target_properties(GitarGame PROPERTIES
    OUTPUT_NAME "GitarGame"
)
