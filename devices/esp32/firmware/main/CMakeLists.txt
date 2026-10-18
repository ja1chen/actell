include("${CMAKE_CURRENT_LIST_DIR}/../../shared/firmware_sources.cmake")
idf_component_register(SRCS "main.c" ${DEVICE_SHARED_SOURCES}
    INCLUDE_DIRS "." ${DEVICE_SHARED_INCLUDE_DIRS}
    PRIV_REQUIRES esp_netif esp_event esp_timer json)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
