cmake_minimum_required(VERSION 3.16)
project(recscribe_activation_probe LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT IS_DIRECTORY "${RECSCRIBE_WHISPER_ROOT}/src")
    message(FATAL_ERROR "Pass the protected pinned source checkout as RECSCRIBE_WHISPER_ROOT")
endif()
find_package(Git REQUIRED)
execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${RECSCRIBE_WHISPER_ROOT}" rev-parse HEAD
    OUTPUT_VARIABLE probe_upstream_commit OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE probe_git_status)
if(NOT probe_git_status EQUAL 0 OR NOT probe_upstream_commit STREQUAL "d1be6fde11ac6e0407606b4e42fe72d34add8037")
    message(FATAL_ERROR "Expected exact whisper.cpp v1.9.5 source commit")
endif()
execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${RECSCRIBE_WHISPER_ROOT}" diff --quiet HEAD --
    RESULT_VARIABLE probe_dirty_status)
if(NOT probe_dirty_status EQUAL 0)
    message(FATAL_ERROR "Pinned upstream tracked source must be unchanged")
endif()

# Reuse the exact installed GGML runtime; do not rebuild a second backend. The
# calling experiment hashes its headers/libraries and records resolved dylibs.
# The source TU below includes unmodified pinned whisper.cpp private internals;
# no app, installed native binary, upstream source or model is changed.
if(NOT IS_DIRECTORY "${RECSCRIBE_GGML_ROOT}/lib/cmake/ggml")
    message(FATAL_ERROR "Pass the installed pinned GGML root as RECSCRIBE_GGML_ROOT")
endif()
find_package(ggml 0.27.0 EXACT CONFIG REQUIRED
    PATHS "${RECSCRIBE_GGML_ROOT}/lib/cmake/ggml" NO_DEFAULT_PATH)
find_package(Threads REQUIRED)
add_executable(recscribe-activation-probe probe.cpp
    "${RECSCRIBE_WHISPER_ROOT}/src/aneforge/whisper-aneforge.cpp")
target_include_directories(recscribe-activation-probe PRIVATE
    "${RECSCRIBE_WHISPER_ROOT}/include" "${RECSCRIBE_WHISPER_ROOT}/src")
target_compile_definitions(recscribe-activation-probe PRIVATE
    WHISPER_VERSION="1.9.5"
    RECSCRIBE_WHISPER_SOURCE="${RECSCRIBE_WHISPER_ROOT}/src/whisper.cpp")
target_link_libraries(recscribe-activation-probe PRIVATE ggml::ggml Threads::Threads ${CMAKE_DL_LIBS})

add_executable(recscribe-activation-stats-test activation_stats_test.cpp)
# assert() remains enabled in the Release diagnostic contract executable.
target_compile_options(recscribe-activation-stats-test PRIVATE -UNDEBUG)
