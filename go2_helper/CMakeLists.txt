cmake_minimum_required(VERSION 3.10)
project(go2_action_helper)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(UNITREE_SDK_DIR "/home/unitree/Downloads/sdk/unitree_sdk2" CACHE PATH "Unitree SDK2 root")
include_directories(
  ${UNITREE_SDK_DIR}/include
  ${UNITREE_SDK_DIR}/thirdparty/include
  ${UNITREE_SDK_DIR}/thirdparty/include/ddscxx
)
link_directories(
  ${UNITREE_SDK_DIR}/thirdparty/lib/aarch64
  ${UNITREE_SDK_DIR}/lib/aarch64
)

add_executable(go2_action_helper go2_action_helper.cpp)
target_link_libraries(go2_action_helper unitree_sdk2 ddsc ddscxx pthread)
set_target_properties(go2_action_helper PROPERTIES
  BUILD_RPATH "${UNITREE_SDK_DIR}/thirdparty/lib/aarch64;${UNITREE_SDK_DIR}/lib/aarch64"
  INSTALL_RPATH "${UNITREE_SDK_DIR}/thirdparty/lib/aarch64;${UNITREE_SDK_DIR}/lib/aarch64"
)
