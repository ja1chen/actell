set(DEVICE_SHARED_DIR "${CMAKE_CURRENT_LIST_DIR}")
set(DEVICE_SHARED_SOURCES
    "${DEVICE_SHARED_DIR}/usb/usb_network.c"
    "${DEVICE_SHARED_DIR}/usb/usb_hid.c"
    "${DEVICE_SHARED_DIR}/usb/protocol.c"
    "${DEVICE_SHARED_DIR}/usb/hid_motion.c"
    "${DEVICE_SHARED_DIR}/ncm/developer_service.c")
foreach(source nd_discovery nd_pairing nd_socket nd_server nd_http nd_relay)
    list(APPEND DEVICE_SHARED_SOURCES "${DEVICE_SHARED_DIR}/ncm/${source}.c")
endforeach()
foreach(source bridge_io bridge_bplist bridge_lockdown_probe)
    list(APPEND DEVICE_SHARED_SOURCES "${DEVICE_SHARED_DIR}/protocol/${source}.c")
endforeach()
if(CONFIG_USB_CONTROL_ENABLED)
    list(APPEND DEVICE_SHARED_SOURCES "${DEVICE_SHARED_DIR}/usb/usb_control.c")
endif()
set(DEVICE_SHARED_INCLUDE_DIRS "${DEVICE_SHARED_DIR}/usb" "${DEVICE_SHARED_DIR}/ncm"
    "${DEVICE_SHARED_DIR}/protocol/include")
