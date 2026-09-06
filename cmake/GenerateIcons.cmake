# Generate app and menu bar icons from their SVG masters.
function(generate_icons)
    set(MASTER_SVG "${CMAKE_SOURCE_DIR}/assets/yakety.svg")
    set(MENUBAR_SVG "${CMAKE_SOURCE_DIR}/assets/menubar.svg")
    set(ICON_DIR "${CMAKE_SOURCE_DIR}/assets/generated")

    find_program(RSVG_COMMAND rsvg-convert)
    if(APPLE)
        find_program(SIPS_COMMAND sips)
    endif()

    file(MAKE_DIRECTORY ${ICON_DIR})

    set(NEED_APP_GENERATION FALSE)
    if(NOT EXISTS "${ICON_DIR}/icon_16x16.png" OR
       NOT EXISTS "${ICON_DIR}/icon_512x512.png" OR
       "${MASTER_SVG}" IS_NEWER_THAN "${ICON_DIR}/icon_512x512.png")
        set(NEED_APP_GENERATION TRUE)
    endif()

    set(NEED_MENUBAR_GENERATION FALSE)
    if(NOT EXISTS "${ICON_DIR}/menubar.png" OR
       NOT EXISTS "${ICON_DIR}/menubar@2x.png" OR
       "${MENUBAR_SVG}" IS_NEWER_THAN "${ICON_DIR}/menubar@2x.png")
        set(NEED_MENUBAR_GENERATION TRUE)
    endif()

    if((NEED_APP_GENERATION OR NEED_MENUBAR_GENERATION) AND NOT RSVG_COMMAND AND NOT SIPS_COMMAND)
        message(WARNING "No SVG renderer found. Install librsvg, or build on macOS with sips available.")
        return()
    endif()

    if(NEED_APP_GENERATION)
        message(STATUS "Generating app icons from master...")

        foreach(size 16 32 48 64 128 256 512 1024)
            set(output "${ICON_DIR}/icon_${size}x${size}.png")
            if(RSVG_COMMAND)
                execute_process(
                    COMMAND ${RSVG_COMMAND} ${MASTER_SVG} -w ${size} -h ${size} -o ${output}
                    RESULT_VARIABLE result
                )
            else()
                execute_process(
                    COMMAND ${SIPS_COMMAND} -s format png --resampleHeightWidth ${size} ${size} ${MASTER_SVG} --out ${output}
                    OUTPUT_QUIET
                    RESULT_VARIABLE result
                )
            endif()
            if(NOT result EQUAL 0)
                message(WARNING "Failed to generate ${size}x${size} icon")
            endif()
        endforeach()

        foreach(size 16 32 64 128 256 512)
            math(EXPR double_size "${size} * 2")
            set(output "${ICON_DIR}/icon_${size}x${size}@2x.png")
            if(RSVG_COMMAND)
                execute_process(
                    COMMAND ${RSVG_COMMAND} ${MASTER_SVG} -w ${double_size} -h ${double_size} -o ${output}
                    RESULT_VARIABLE result
                )
            else()
                execute_process(
                    COMMAND ${SIPS_COMMAND} -s format png --resampleHeightWidth ${double_size} ${double_size} ${MASTER_SVG} --out ${output}
                    OUTPUT_QUIET
                    RESULT_VARIABLE result
                )
            endif()
            if(NOT result EQUAL 0)
                message(WARNING "Failed to generate ${size}x${size}@2x icon")
            endif()
        endforeach()
    endif()

    if(NEED_MENUBAR_GENERATION)
        message(STATUS "Generating menu bar icons from master...")

        if(RSVG_COMMAND)
            execute_process(
                COMMAND ${RSVG_COMMAND} ${MENUBAR_SVG} -w 22 -h 22 -o "${ICON_DIR}/menubar.png"
                RESULT_VARIABLE menubar_result
            )
            execute_process(
                COMMAND ${RSVG_COMMAND} ${MENUBAR_SVG} -w 44 -h 44 -o "${ICON_DIR}/menubar@2x.png"
                RESULT_VARIABLE menubar_retina_result
            )
        else()
            execute_process(
                COMMAND ${SIPS_COMMAND} -s format png --resampleHeightWidth 22 22 ${MENUBAR_SVG} --out "${ICON_DIR}/menubar.png"
                OUTPUT_QUIET
                RESULT_VARIABLE menubar_result
            )
            execute_process(
                COMMAND ${SIPS_COMMAND} -s format png --resampleHeightWidth 44 44 ${MENUBAR_SVG} --out "${ICON_DIR}/menubar@2x.png"
                OUTPUT_QUIET
                RESULT_VARIABLE menubar_retina_result
            )
        endif()

        if(NOT menubar_result EQUAL 0 OR NOT menubar_retina_result EQUAL 0)
            message(WARNING "Failed to generate menu bar icons")
        endif()
    endif()

    if(APPLE AND (NEED_APP_GENERATION OR NOT EXISTS "${CMAKE_SOURCE_DIR}/assets/yakety.icns"))
        set(ICONSET_DIR "${CMAKE_BINARY_DIR}/yakety.iconset")
        file(REMOVE_RECURSE ${ICONSET_DIR})
        file(MAKE_DIRECTORY ${ICONSET_DIR})

        foreach(icon
                icon_16x16.png icon_16x16@2x.png
                icon_32x32.png icon_32x32@2x.png
                icon_128x128.png icon_128x128@2x.png
                icon_256x256.png icon_256x256@2x.png
                icon_512x512.png icon_512x512@2x.png)
            file(COPY "${ICON_DIR}/${icon}" DESTINATION ${ICONSET_DIR})
        endforeach()

        execute_process(
            COMMAND iconutil -c icns -o "${CMAKE_SOURCE_DIR}/assets/yakety.icns" ${ICONSET_DIR}
            RESULT_VARIABLE result
        )
        file(REMOVE_RECURSE ${ICONSET_DIR})

        if(result EQUAL 0)
            message(STATUS "Generated yakety.icns")
        else()
            message(WARNING "Failed to generate yakety.icns")
        endif()
    endif()

    if(WIN32 OR MINGW)
        find_program(MAGICK_COMMAND magick)
        if(NOT MAGICK_COMMAND)
            find_program(MAGICK_COMMAND convert)
        endif()

        if(MAGICK_COMMAND AND
           (NOT EXISTS "${CMAKE_SOURCE_DIR}/assets/yakety.ico" OR
            "${MASTER_SVG}" IS_NEWER_THAN "${CMAKE_SOURCE_DIR}/assets/yakety.ico"))
            execute_process(
                COMMAND ${MAGICK_COMMAND} ${MASTER_SVG}
                        -define icon:auto-resize=256,128,64,48,32,16
                        "${CMAKE_SOURCE_DIR}/assets/yakety.ico"
                RESULT_VARIABLE result
            )
            if(result EQUAL 0)
                message(STATUS "Generated yakety.ico")
            else()
                message(WARNING "Failed to generate yakety.ico")
            endif()
        elseif(NOT MAGICK_COMMAND)
            message(WARNING "ImageMagick not found. Keeping the existing Windows icon.")
        endif()
    endif()
endfunction()
