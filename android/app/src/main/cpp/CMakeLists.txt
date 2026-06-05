cmake_minimum_required(VERSION 3.22.1)
project("narrator_ncnn")

# NCNN headers & prebuilt libs — expected in android/app/src/main/jni/ncnn/
set(NCNN_DIR ${CMAKE_SOURCE_DIR}/ncnn)

add_library(narrator_ncnn SHARED narrator_ncnn.cpp)

# Include NCNN headers
target_include_directories(narrator_ncnn PRIVATE ${NCNN_DIR}/include)

# Link prebuilt NCNN static lib for this ABI
add_library(ncnn STATIC IMPORTED)
set_target_properties(ncnn PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libncnn.a)

# glslang libs required by NCNN's GPU/Vulkan compilation path
add_library(glslang STATIC IMPORTED)
set_target_properties(glslang PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libglslang.a)

add_library(glslang_default_resource_limits STATIC IMPORTED)
set_target_properties(glslang_default_resource_limits PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libglslang-default-resource-limits.a)

add_library(spirv STATIC IMPORTED)
set_target_properties(spirv PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libSPIRV.a)

add_library(machine_independent STATIC IMPORTED)
set_target_properties(machine_independent PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libMachineIndependent.a)

add_library(generic_code_gen STATIC IMPORTED)
set_target_properties(generic_code_gen PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libGenericCodeGen.a)

add_library(os_dependent STATIC IMPORTED)
set_target_properties(os_dependent PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libOSDependent.a)

target_link_libraries(narrator_ncnn
    ncnn
    glslang
    glslang_default_resource_limits
    spirv
    machine_independent
    generic_code_gen
    os_dependent
    # -fopenmp -static-openmp: required — libncnn.a has 1230+ OpenMP symbol
    # references (__kmpc_fork_call, __kmpc_for_static_init etc.) that must
    # be resolved at link time. Runtime parallelism is suppressed instead
    # by calling omp_set_num_threads(1) + omp_set_dynamic(0) in narrator_ncnn.cpp.
    -fopenmp -static-openmp
    android
    log
    z)

# ── Llama.cpp integration (JNI, on-device inference) ────────────────
# Build core library + mtmd multimodal toolkit only — no server/CLI tools
set(LLAMA_BUILD_TESTS    OFF)
set(LLAMA_BUILD_EXAMPLES OFF)
set(LLAMA_BUILD_TOOLS    OFF)
set(LLAMA_BUILD_SERVER   OFF)
set(LLAMA_BUILD_COMMON   ON)    # needed by mtmd
add_subdirectory(llama.cpp)

# mtmd lives under tools/ but is a self-contained library.
# Include it directly so we don't have to enable LLAMA_BUILD_TOOLS.
# mtmd/CMakeLists.txt uses LLAMA_INSTALL_VERSION in set_target_properties —
# if it's undefined/empty, CMake errors with "wrong number of arguments".
# The llama.cpp add_subdirectory above normally defines this, but just in case:
if(NOT DEFINED LLAMA_INSTALL_VERSION OR "x${LLAMA_INSTALL_VERSION}" STREQUAL "x")
    set(LLAMA_INSTALL_VERSION "0")
endif()
add_subdirectory(llama.cpp/tools/mtmd)

# Mark the CLI executables from mtmd as EXCLUDE_FROM_ALL so they are never
# linked (they require llama-common which we are not building on Android).
set_target_properties(llama-llava-cli    PROPERTIES EXCLUDE_FROM_ALL TRUE)
set_target_properties(llama-gemma3-cli   PROPERTIES EXCLUDE_FROM_ALL TRUE)
set_target_properties(llama-minicpmv-cli PROPERTIES EXCLUDE_FROM_ALL TRUE)
set_target_properties(llama-qwen2vl-cli  PROPERTIES EXCLUDE_FROM_ALL TRUE)
set_target_properties(llama-mtmd-cli     PROPERTIES EXCLUDE_FROM_ALL TRUE)
set_target_properties(llama-mtmd-debug   PROPERTIES EXCLUDE_FROM_ALL TRUE)

# ── narrator_vlm: JNI bridge for on-device VLM inference ────────────
add_library(narrator_vlm SHARED
    narrator_vlm_jni.cpp
)

target_include_directories(narrator_vlm PRIVATE
    # llama.cpp public headers
    ${CMAKE_SOURCE_DIR}/llama.cpp/include
    ${CMAKE_SOURCE_DIR}/llama.cpp/ggml/include
    # mtmd multimodal toolkit headers
    ${CMAKE_SOURCE_DIR}/llama.cpp/tools/mtmd
)

target_link_libraries(narrator_vlm PRIVATE
    llama          # core inference engine
    mtmd           # multimodal toolkit (image tokeniser / vision encoder)
    ggml
    ggml-base
    android
    log
)
# ── Whisper mel spectrogram (native C++ for accuracy) ───────────────
add_library(whisper_mel SHARED
    whisper_mel.cpp
)
target_link_libraries(whisper_mel PRIVATE
    android
    log
)
target_compile_features(whisper_mel PRIVATE cxx_std_17)
target_compile_options(whisper_mel PRIVATE -O3 -ffast-math)

target_compile_features(narrator_vlm PRIVATE cxx_std_17)
