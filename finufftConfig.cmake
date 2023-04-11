get_filename_component(finufft_INSTALL_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)

# Define the cmake installation directory:
set(finufft_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

# Provide all the library targets:
include("${CMAKE_CURRENT_LIST_DIR}/finufftTargets.cmake")

# Include all the custom cmake scripts ...

# Define the include directories:
set(finufft_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(finufft_LIBRARY_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../../lib"     )
set(finufft_LIBRARYS      -lfinufft cufinufft)

set(SupportedComponents finufft cufinufft)

set(finufft_FOUND True)

# Check that all the components are found:
# And add the components to the Foo_LIBS parameter:
foreach(comp ${finufft_FIND_COMPONENTS})
  if (NOT ";${SupportedComponents};" MATCHES comp)
    set(finufft_FOUND False)
    set(finufft_NOT_FOUND_MESSAGE "Unsupported component: ${comp}")
  endif()
  set(finufft_LIBS "${finufft_LIBS} -l{comp}")
  if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/finufft${comp}Targets.cmake")
    include("${CMAKE_CURRENT_LIST_DIR}/finufft${comp}Targets.cmake")
  endif()
endforeach()