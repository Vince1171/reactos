
spec2def(wldap32.dll wldap32.spec ADD_IMPORTLIB)

list(APPEND SOURCE
    add.c
    bind.c
    compare.c
    control.c
    delete.c
    dn.c
    error.c
    extended.c
    init.c
    main.c
    misc.c
    modify.c
    modrdn.c
    option.c
    page.c
    parse.c
    rename.c
    search.c
    value.c)

list(APPEND PCH_SKIP_SOURCE
    ber.c)

add_library(wldap32 MODULE
    ${SOURCE}
    ${PCH_SKIP_SOURCE}
    wldap32.rc
    ${CMAKE_CURRENT_BINARY_DIR}/wldap32_stubs.c
    ${CMAKE_CURRENT_BINARY_DIR}/wldap32.def)

set_module_type(wldap32 win32dll)
target_link_libraries(wldap32 wine)
add_importlibs(wldap32 user32 msvcrt kernel32 ntdll)
add_pch(wldap32 precomp.h "${PCH_SKIP_SOURCE}")
add_cd_file(TARGET wldap32 DESTINATION reactos/system32 FOR all)
set_wine_module_FIXME(wldap32) # CORE-5743: No ARRAY_SIZE macro
