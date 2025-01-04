/*
 * PROJECT:     FreeLoader
 * LICENSE:     MIT (https://spdx.org/licenses/MIT)
 * PURPOSE:     EXTFS second stage loader
 * COPYRIGHT:   Copyright 2024 Daniel Victor <ilauncherdeveloper@gmail.com>
 */

#define INCLUDED_ASM
#include "ext.S"

#define EXT_MAXIMUM_DIR_ENTRIES_BUFFER_SIZE HEX(F000)

ExtLdrEntryPoint:
    /* Clear segment registers */
    xor eax, eax
    mov ds, ax
    mov es, ax

    /* Read root directory Inode */
    mov al, EXT_ROOT_INO
    call ExtReadInode

    /* Set file base address and read entire Inode data to search for freeldr */
    mov dword ptr BP_REL(ExtFileAddress), EXT_BLOCK_ADDRESS
    call ExtReadEntireFile

    /* Set correct segment */
    mov si, EXT_BLOCK_ADDRESS / 16
    mov ds, si
    xor si, si
    mov es, si

    /* Get directory entry size */
    mov edx, dword ptr BP_REL(ExtFileSize)

    /* Set the buffer size with limit */
    cmp edx, EXT_MAXIMUM_DIR_ENTRIES_BUFFER_SIZE
    jbe .FLoop2
    mov edx, EXT_MAXIMUM_DIR_ENTRIES_BUFFER_SIZE
.FLoop2:
    /* Load directory Inode */
    mov eax, dword ptr ds:[si]

    /* If the buffer reached the end then abort it */
    cmp si, dx
    jae FreeLdrPrintFileNotFound

    /* If the Inode is zero then abort it */
    test eax, eax
    jz FreeLdrPrintFileNotFound

    push si                                                 // Save SI
    add si, 8                                               // Move to filename in entry
    mov di, offset FreeLdrFileName                          // Load target filename address
    mov cx, offset FreeLdrFileNameEnd - FreeLdrFileName     // Length of filename to compare
    repe cmpsb                                              // Compare filenames
    pop si                                                  // Restore SI
    jz LoadFreeLdr                                          // Found matching file

    /* Move to next directory entry */
    add si, word ptr ds:[si + 4]

    jmp .FLoop2

ExtFileIndirectPointer:
    .long 0
ExtFileIndirectPointerDouble:
    .long 0

SwapESWithDS:
    /* Swap ES and DS */
    push es
    push ds
    pop es
    pop ds
    ret

ExtSetFileSegment:
    mov ebx, dword ptr BP_REL(ExtFileAddress)           // Get the EXT file address
    shr ebx, 4                                          // Shift four bits to the right to get segment
    jmp .ExtSkip
ExtSetInodeSegment:
    mov bx, EXT_INODE_ADDRESS / 16                      // Get the EXT inode address
    jmp .ExtSkip
ExtSetBlockSegment:
    mov bx, EXT_BLOCK_ADDRESS / 16                      // Get the EXT block address
    jmp .ExtSkip
ExtSetBlock2Segment:
    mov bx, EXT_BLOCK2_ADDRESS / 16                     // Get the EXT second block address
.ExtSkip:
    mov es, bx                                          // Set ES
    xor bx, bx                                          // Clear BX
    ret

ExtSafeReadBlock:
    pushad

    test eax, eax
    jz .NullBlk

    call ExtReadBlock
    jmp .RBDone
.NullBlk:
    mov di, bx
    xor ax, ax
    mov cx, word ptr BP_REL(ExtBlockSizeInBytes)
    rep stosb
.RBDone:
    popad
    ret

ExtFileReadBlock:
    push es
    pushad

    call ExtSetFileSegment
    call ExtSafeReadBlock

    mov ecx, dword ptr BP_REL(ExtBlockSizeInBytes)
    sub dword ptr BP_REL(ExtFileSizeState), ecx
    add dword ptr BP_REL(ExtFileAddress), ecx

    popad
    pop es
    ret

ExtReadEntireFileDone:
    push eax
    mov eax, dword ptr BP_REL(ExtBlockSizeInBytes)
    cmp dword ptr BP_REL(ExtFileSizeState), eax
    pop eax
    ret

ExtReadEntireFileLoop:
    call ExtReadEntireFileDone
    jb .RDone

    mov eax, dword ptr es:[si]

    call ExtFileReadBlock

    add si, 4
    loop ExtReadEntireFileLoop
.RDone:
    ret

ExtReadEntireFileIndirectDouble:
    push es
    pushad

    call ExtReadEntireFileDone
    jb .RDone4

    xor si, si
    mov eax, dword ptr BP_REL(ExtFileIndirectPointerDouble)
    call ExtSetBlock2Segment
    call ExtSafeReadBlock
    mov ecx, dword ptr BP_REL(ExtPointersPerBlock)
.RLoop4:
    call ExtReadEntireFileDone
    jb .RDone4

    mov eax, dword ptr es:[si]

    call ExtReadEntireFileIndirect

    add si, 4
    loop .RLoop4
.RDone4:
    popad
    pop es
    ret

ExtReadEntireFileIndirect:
    push es
    pushad

    call ExtReadEntireFileDone
    jb .RDone3

    xor si, si
    call ExtSetBlockSegment
    call ExtSafeReadBlock
    mov ecx, dword ptr BP_REL(ExtPointersPerBlock)

    call ExtReadEntireFileLoop
.RDone3:
    popad
    pop es
    ret

ExtReadEntireFileDirect:
    push es
    pushad

    call ExtReadEntireFileDone
    jb .RDone2

    add si, 40
    xor ecx, ecx
    mov cl, EXT_INODE_BLOCKS

    call ExtSetInodeSegment
    call ExtReadEntireFileLoop
.RDone2:
    popad
    pop es
    ret

ExtReadEntireFile:
    /* Set the correct Inode offset */
    mov si, word ptr BP_REL(ExtReadInodeIndexOffset)

    /* Set file size */
    mov ecx, dword ptr es:[si + 4]
    mov dword ptr BP_REL(ExtFileSize), ecx

    /* If file size is zero then abort it */
    test ecx, ecx
    jz FreeLdrPrintFileZero

    /* Set rounded up file size */
    add ecx, dword ptr BP_REL(ExtBlockSizeInBytes)
    dec ecx
    mov dword ptr BP_REL(ExtFileSizeState), ecx

    /* Set Indirect pointer */
    mov eax, dword ptr es:[si + (40 + (EXT_INODE_BLOCKS * 4))]
    mov dword ptr BP_REL(ExtFileIndirectPointer), eax

    /* Set Double indirect pointer */
    mov eax, dword ptr es:[si + (44 + (EXT_INODE_BLOCKS * 4))]
    mov dword ptr BP_REL(ExtFileIndirectPointerDouble), eax

    call ExtReadEntireFileDirect                                // Read the direct blocks

    mov eax, dword ptr BP_REL(ExtFileIndirectPointer)           // Load the simple indirect pointer
    call ExtReadEntireFileIndirect                              // Read the simple indirect blocks

    call ExtReadEntireFileIndirectDouble                        // Read the double indirect blocks

    ret

LoadFreeLdr:
    /* Swap ES and DS */
    call SwapESWithDS

    /* Show output loading status */
    push si
    mov si, offset msgLoadingFreeLdr
    call PutChars
    pop si

    /* Load Inode at directory entry */
    mov eax, dword ptr es:[si]
    call ExtReadInode
    mov si, word ptr BP_REL(ExtReadInodeIndexOffset)

    /* Get Inode type */
    mov ax, word ptr es:[si]
    and ax, EXT_INODE_TYPE_MASK

    /* If it's not a regular file then abort it */
    cmp ax, EXT_INODE_TYPE_REGULAR
    jnz FreeLdrPrintRegFileError

    /* Load Freeldr at FREELDR_BASE */
    mov dword ptr BP_REL(ExtFileAddress), FREELDR_BASE
    call ExtReadEntireFile

    /* Restore the boot drive and partition */
    mov dl, byte ptr BP_REL(BootDrive)
    mov dh, byte ptr BP_REL(BootPartition)

    /* Transfer execution to the bootloader */
    ljmp16 FREELDR_BASE / 16, 0

FreeLdrPrintFileZero:
    /* Make DS correct */
    xor ax, ax
    mov ds, ax

    mov si, offset msgFreeLdrZero
    jmp DisplayItAndReboot
FreeLdrPrintFileNotFound:
    /* Make DS correct */
    xor ax, ax
    mov ds, ax

    mov si, offset msgFreeLdr
    jmp DisplayItAndReboot
FreeLdrPrintRegFileError:
    /* Make DS correct */
    xor ax, ax
    mov ds, ax

    mov si, offset msgFreeLdrNotRegularFile     // FreeLdr not found message
    jmp DisplayItAndReboot

msgFreeLdrZero:
    .ascii "freeldr.sys size is zero", CR, LF, NUL
msgFreeLdr:
    .ascii "freeldr.sys not found", CR, LF, NUL
msgFreeLdrNotRegularFile:
    .ascii "freeldr.sys is not a regular file", CR, LF, NUL
FreeLdrFileName:
    .ascii "freeldr.sys"
FreeLdrFileNameEnd:
msgLoadingFreeLdr:
    .ascii "Loading FreeLoader...", CR, LF, NUL

.org 2046
    .word HEX(0aa55)       // BootSector signature

.endcode16

END
