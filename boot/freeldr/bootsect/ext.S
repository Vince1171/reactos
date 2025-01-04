/*
 * PROJECT:     FreeLoader
 * LICENSE:     MIT (https://spdx.org/licenses/MIT)
 * PURPOSE:     EXTFS volume boot sector
 * COPYRIGHT:   Copyright 2002-2003 Brian Palmer <brianp@sginet.com>
 *              Copyright 2024 Daniel Victor <ilauncherdeveloper@gmail.com>
 */

#include <asm.inc>
#include <freeldr/include/arch/pc/x86common.h>

#define EXT_INODE_BLOCKS                12
#define EXT_INODE_INDIRECT_BLOCKS       3
#define EXT_ROOT_INO                    2
#define EXT_BLOCK_SIZE                  1024
#define EXT_INODE_ADDRESS               HEX(9000)
#define EXT_BLOCK_ADDRESS               HEX(A000)
#define EXT_BLOCK2_ADDRESS              HEX(B000)
#define EXT_INODE_TYPE_MASK             HEX(F000)
#define EXT_INODE_TYPE_REGULAR          HEX(8000)

#define ExtReadBlockOffset              2
#define ExtReadInodeOffset              4
#define DisplayItAndRebootOffset        6
#define PutCharsOffset                  8

#define BootSectorStackSubtract         16

.code16

#ifndef INCLUDED_ASM
#define BP_REL(x) ss:[bp+x-offset start]

start:
    jmp main

.org 3

/* Fields that will be changed by the installer */
BootDrive:
    .byte HEX(FF)
ExtVolumeStartSector:
    .long 263088				// Start sector of the ext2 volume
ExtBlockSize:
    .long 2						// Block size in sectors
ExtBlockSizeInBytes:
    .long 1024					// Block size in bytes
ExtPointersPerBlock:
    .long 256					// Number of block pointers that can be contained in one block
ExtGroupDescSize:
    .long 32 					// Size of Group Descriptor
ExtFirstDataBlock:
    .long 2						// First data block (2 for 1024-byte blocks, 1 for bigger sizes)
ExtInodeSize:
    .long 128					// Size of Inode
ExtInodesPerGroup:
    .long 2048					// Number of inodes per group

/* File variables */
ExtFileSize:
    .long 0                     // File size in bytes
ExtFileSizeState:
    .long 0                     // File size in bytes (used in loops)
ExtFileAddress:
    .long 0                     // File address

/* Inode variables */
ExtReadInodeGroup:
    .long 0
ExtReadInodeIndex:
    .long 0
ExtReadInodeGroupBlock:
    .long 0
ExtReadInodeIndexBlock:
    .long 0
ExtReadInodeGroupOffset:
    .word 0
ExtReadInodeIndexOffset:
    .word 0

/* LBA variables */
LBASectorsRead:
    .long 0

main:
    xor ax, ax                  // Setup segment registers
    mov ds, ax                  // Make DS correct
    mov es, ax                  // Make ES correct
    mov ss, ax				    // Make SS correct
    mov bp, HEX(7c00)
    mov sp, bp                  // Setup a stack
    sub sp, BootSectorStackSubtract

    /* Save the function address so 'extldr.sys' code knows where to call them */
    mov word ptr ss:[bp-ExtReadBlockOffset],            offset ExtReadBlock
    mov word ptr ss:[bp-ExtReadInodeOffset],            offset ExtReadInode
    mov word ptr ss:[bp-DisplayItAndRebootOffset],      offset DisplayItAndReboot
    mov word ptr ss:[bp-PutCharsOffset],                offset PutChars

    mov si, offset BootDrive
    cmp byte ptr [si], HEX(0ff)	// If they have specified a boot drive then use it
    jne CheckInt13hExtensions

    mov [si], dl				// Save the boot drive

// Now check if this computer supports extended reads. This boot sector will not work without it
CheckInt13hExtensions:
    mov ah, HEX(41)             // AH = 41h
    mov bx, HEX(55aa)           // BX = 55AAh
    int HEX(13)                 // IBM/MS INT 13 Extensions - INSTALLATION CHECK
    jc PrintDiskError           // CF set on error (extensions not supported)
    cmp  bx, HEX(aa55)          // BX = AA55h if installed
    jne PrintDiskError
    test cl, 1                  // si = API subset support bitmap
    jz PrintDiskError           // Bit 0, extended disk access functions (AH=42h-44h,47h,48h) supported

LoadExtraBootCode:
    // First we have to load our extra boot code at
    // sector 1 into memory at [0000:7e00h]
    xor eax, eax
    inc eax
    mov cx, 3
    xor bx, bx
    mov es, bx                  // Read sector to [0000:7e00h]
    mov bx, HEX(7e00)
    call ReadSectors

    jmp  LoadRootDirectory

// Reads logical sectors into ES:[BX]
// EAX has logical sector number to read
// CX has number of sectors to read
ReadSectors:
    push es
    add  eax, dword ptr BP_REL(ExtVolumeStartSector)	// Add the start of the volume
                                                        // If at all possible we want to use LBA routines because
                                                        // They are optimized to read more than 1 sector per read

ReadSectorsLBA:
    pushad                                      // Save logical sector number & sector count

    cmp  cx, 64                                 // Since the LBA calls only support 0x7F sectors at a time we will limit ourselves to 64
    jbe  ReadSectorsSetupDiskAddressPacket      // If we are reading less than 65 sectors then just do the read
    mov  cx, 64                                 // Otherwise read only 64 sectors on this loop iteration

ReadSectorsSetupDiskAddressPacket:
    mov word ptr BP_REL(LBASectorsRead),cx
    push 0
    push 0
    push eax                                // Put 64-bit logical block address on stack
    push es                                 // Put transfer segment on stack
    push bx                                 // Put transfer offset on stack
    push cx                                 // Set transfer count
    push 16                                 // Set size of packet to 10h
    mov  si, sp                             // Setup disk address packet on stack

    mov  dl, byte ptr BP_REL(BootDrive)     // Drive number
    mov  ah, HEX(42)                        // Int 13h, AH = 42h - Extended Read
    int  HEX(13)                            // Call BIOS
    jc   PrintDiskError                     // If the read failed then abort

    add  sp, 16                             // Remove disk address packet from stack

    popad                                   // Restore sector count & logical sector number

    push bx
    mov  ebx, dword ptr BP_REL(LBASectorsRead)
    add  eax, ebx                           // Increment sector to read
    shl  ebx, 5
    mov  dx, es
    add  dx, bx                             // Setup read buffer for next sector
    mov  es, dx
    pop  bx

    sub  cx, word ptr BP_REL(LBASectorsRead)
    jnz  ReadSectorsLBA                     // Read next sector

    pop es
    ret

// Displays a disk error message
// And reboots
PrintDiskError:
    mov si, offset msgDiskError			// Bad boot disk message
    call PutChars					    // Display it

Reboot:
    mov si, offset msgAnyKey            // Press any key message
    call PutChars                       // Display it
    xor ax, ax
    int HEX(16)                         // Wait for a keypress
    int HEX(19)                         // Reboot

.PutCharsLoop:
    mov ah, HEX(0E)
    mov bx, 7
    int HEX(10)
PutChars:
    lodsb
    or al, al
    jnz .PutCharsLoop
    ret

SwapESWithDS:
    /* Swap ES and DS */
    push es
    push ds
    pop es
    pop ds
    ret

ExtReadGroupDescriptor:
    mov eax, dword ptr BP_REL(ExtReadInodeGroupBlock)   // Get Inode group block
    add eax, dword ptr BP_REL(ExtFirstDataBlock)        // Add the Group Descriptor offset
    call ExtSetInodeSegment

ExtReadBlock:
    xor edx, edx
    mov ecx, dword ptr BP_REL(ExtBlockSize)
    mul ecx
    jmp ReadSectors

// EAX
ExtCalculateBlock:
    xor edx, edx										// Clear EDX before division
    div dword ptr BP_REL(ExtBlockSizeInBytes)			// Inode * /= ExtBlockSizeInBytes
    mov dword ptr ds:[bp + si], eax	                    // Store the Inode * block
    ret

// SI, DI
ExtCalculateOffset:
    add bx, bp                                          // Sum BX with BP for absolute address
    xor edx, edx										// Clear EDX before multiplication
    mov eax, dword ptr ds:[bp + si]                     // Get the Inode * block
    mul dword ptr BP_REL(ExtBlockSizeInBytes)			// Inode index *= ExtBlockSizeInBytes
    mov ecx, dword ptr ds:[bx]		                    // Get the Inode *
    sub ecx, eax										// Subtract the original Inode * with rounded down Inode group
    mov word ptr ds:[bp + di], cx	                    // Store the rounded down Inode *
    ret

ExtSetFileSegment:
    mov ebx, dword ptr BP_REL(ExtFileAddress)           // Get the EXT file address
    shr ebx, 4                                          // Shift four bits to the right to get segment
    jmp .ExtSkip
ExtSetInodeSegment:
    mov bx, EXT_INODE_ADDRESS / 16                      // Get the EXT inode address
.ExtSkip:
    mov es, bx                                          // Set ES
    xor bx, bx                                          // Clear BX
    ret

/* Read the Inode in EAX register */
ExtReadInode:
    xor edx, edx										// Clear EDX before division
    dec eax												// Inode = Inode -1
    div dword ptr BP_REL(ExtInodesPerGroup)				// Inode /= ExtInodesPerGroup
    mov dword ptr BP_REL(ExtReadInodeGroup), eax		// Store the Inode group
    mov dword ptr BP_REL(ExtReadInodeIndex), edx		// Store the Inode index

    xor edx, edx 										// Clear EDX before multiplication
    mul dword ptr BP_REL(ExtGroupDescSize)				// Inode group *= ExtGroupDescSize
    mov dword ptr BP_REL(ExtReadInodeGroup), eax		// Store the precalculated Inode group

    xor edx, edx										// Clear EDX before multiplication
    mov eax, dword ptr BP_REL(ExtReadInodeIndex)		// Get the read Inode index
    mul dword ptr BP_REL(ExtInodeSize)					// Inode group *= ExtInodeSize
    mov dword ptr BP_REL(ExtReadInodeIndex), eax		// Store the Inode index

    /* Calculate the Inode index block */
    mov si, offset ExtReadInodeIndexBlock - start
    call ExtCalculateBlock

    /* Calculate the Inode group block */
    mov eax, dword ptr BP_REL(ExtReadInodeGroup)
    mov si, offset ExtReadInodeGroupBlock - start
    call ExtCalculateBlock

    /* Calculate the Inode group offset */
    mov bx, offset ExtReadInodeGroup - start
    mov si, offset ExtReadInodeGroupBlock - start
    mov di, offset ExtReadInodeGroupOffset - start
    call ExtCalculateOffset

    /* Calculate the Inode index offset */
    mov bx, offset ExtReadInodeIndex - start
    mov si, offset ExtReadInodeIndexBlock - start
    mov di, offset ExtReadInodeIndexOffset - start
    call ExtCalculateOffset

    /* Read group descriptor */
    call ExtReadGroupDescriptor

    /* Set the offset address */
    mov si, word ptr BP_REL(ExtReadInodeGroupOffset)

    /* Get InodeTable field from the ExtGroupDescriptor structure */
    mov eax, dword ptr es:[si + 8]

    /* Sum EAX with Inode index block */
    add eax, dword ptr BP_REL(ExtReadInodeIndexBlock)

    jmp ExtReadBlock

msgDiskError:
    .ascii "Disk error", CR, LF, NUL
msgAnyKey:
    .ascii "Press any key", CR, LF, NUL

.org 509

BootPartition:
    .byte 0

.word HEX(0aa55)       // BootSector signature

// End of bootsector
//
// Now starts the extra boot code that we will store
// at sector 1 on a EXT2 volume

LoadRootDirectory:
    xor eax, eax
    mov al, EXT_ROOT_INO			// Put the root directory inode number in EAX
    call ExtReadInode				// Read the inode

    call ReadDirectPointers         // Read the direct pointers
    call FindFile                   // Find the extended loader and run it

    jmp ExtLdrPrintFileNotFound

ReadDirectPointers:
    push es
    pushad
    xor eax, eax                                        // Clear eax register because it will be used for multiplication
    call ExtSetInodeSegment

    mov si, word ptr BP_REL(ExtReadInodeIndexOffset)

    mov dword ptr BP_REL(ExtFileAddress), FREELDR_BASE

    /* Calculate direct pointers amount with block size and enforce limits */
    mov al, EXT_INODE_BLOCKS
    mul dword ptr BP_REL(ExtBlockSizeInBytes)

    /* Load file size from memory */
    mov ebx, dword ptr es:[si + 4]

    /* Compare and limit file size */
    cmp ebx, eax
    jbe .BelowOrEqualSize
    mov ebx, eax
.BelowOrEqualSize:
    mov dword ptr BP_REL(ExtFileSize), ebx

    /* Set rounded up file size */
    add ebx, dword ptr BP_REL(ExtBlockSizeInBytes)
    dec ebx
    mov dword ptr BP_REL(ExtFileSizeState), ebx

    xor ecx, ecx
    mov cl, EXT_INODE_BLOCKS
    add si, 40
.LLoop:
    call ExtSetInodeSegment

    mov eax, dword ptr BP_REL(ExtFileSizeState)
    cmp eax, dword ptr BP_REL(ExtBlockSizeInBytes)
    jb .LDone

    mov eax, dword ptr es:[si]

    call ExtSetFileSegment

    test eax, eax
    jz .LFillBlock

    call ExtReadBlock
    jmp .LLoopEnd
.LFillBlock:
    xor di, di
    xor ax, ax
    mov cx, word ptr BP_REL(ExtBlockSizeInBytes)
    rep stosb
.LLoopEnd:
    mov eax, dword ptr BP_REL(ExtBlockSizeInBytes)
    sub dword ptr BP_REL(ExtFileSizeState), eax
    add dword ptr BP_REL(ExtFileAddress), eax

    add si, 4
    loop .LLoop
.LDone:
    mov dword ptr BP_REL(ExtFileAddress), FREELDR_BASE
    popad
    pop es
    ret

FindFile:
    call ExtSetFileSegment
    call SwapESWithDS

    xor si, si
    mov dx, word ptr BP_REL(ExtFileSize)
.FLoop:
    mov eax, dword ptr ds:[si]                              // Load directory Inode

    cmp si, dx                                              // End of buffer reached?
    jae .Done                                               // Exit loop if yes

    test eax, eax                                           // Check if Inode is zero
    jz .Done                                                // Exit loop if yes

    push si                                                 // Save SI
    add si, 8                                               // Move to filename in entry
    mov di, offset ExtLdrFileName                           // Load target filename address
    mov cx, offset ExtLdrFileNameEnd - ExtLdrFileName       // Length of filename to compare
    repe cmpsb                                              // Compare filenames
    pop si                                                  // Restore SI
    jz LoadExtLdr                                           // Found matching file

    add si, word ptr ds:[si + 4]                            // Move to next directory entry
    jmp .FLoop                                              // Continue looping
.Done:
    ret                                                     // Return

LoadExtLdr:
    /* Swap ES and DS */
    call SwapESWithDS

    push si                                                 // Save SI
    mov si, offset msgLoadingExtLdr                         // Point SI to a loading message
    call PutChars                                           // Show the message
    pop si                                                  // Restore SI

    mov eax, dword ptr es:[si]                              // Load directory Inode
    call ExtReadInode                                       // Read the inode
    mov si, word ptr BP_REL(ExtReadInodeIndexOffset)        // Set the correct offset

    /* Get Inode type */
    mov ax, word ptr es:[si]
    and ax, EXT_INODE_TYPE_MASK

    cmp ax, EXT_INODE_TYPE_REGULAR                          // Check if regular file
    jnz ExtLdrPrintRegFileError                             // If not, handle error

    call ReadDirectPointers                                 // Read the direct pointers
    call ExtSetFileSegment                                  // Set file segment
    call SwapESWithDS                                       // Swap ES with DS before copy

    /* Copy the loaded file to 1KB ahead of this bootsector */
    xor si, si
    mov di, offset ExtLdrEntryPoint
    mov cx, EXT_BLOCK_SIZE * 2
    rep movsb

    jmp ExtLdrEntryPoint

ExtLdrPrintFileNotFound:
    /* Make DS correct */
    call SwapESWithDS

    mov si, offset msgExtLdr
    jmp DisplayItAndReboot
ExtLdrPrintRegFileError:
    mov si, offset msgExtLdrNotRegularFile      // ExtLdr not found message
DisplayItAndReboot:
    call PutChars                               // Display it
    jmp Reboot

msgExtLdr:
    .ascii "extldr.sys not found", CR, LF, NUL
msgExtLdrNotRegularFile:
    .ascii "extldr.sys is not a regular file", CR, LF, NUL
ExtLdrFileName:
    .ascii "extldr.sys"
ExtLdrFileNameEnd:
msgLoadingExtLdr:
    .ascii "Loading ExtendedLoader...", CR, LF, NUL

.org 1022

.word HEX(0aa55)       // BootSector signature

ExtLdrEntryPoint:

.endcode16

END

#else

#define start HEX(7C00)
#define BP_REL(x) ss:[bp+x-start]

#define BootDrive                   (start + 3)
#define ExtVolumeStartSector        (BootDrive + 1)
#define ExtBlockSize                (ExtVolumeStartSector + 4)
#define ExtBlockSizeInBytes         (ExtBlockSize + 4)
#define ExtPointersPerBlock         (ExtBlockSizeInBytes + 4)
#define ExtGroupDescSize            (ExtPointersPerBlock + 4)
#define ExtFirstDataBlock           (ExtGroupDescSize + 4)
#define ExtInodeSize                (ExtFirstDataBlock + 4)
#define ExtInodesPerGroup           (ExtInodeSize + 4)

#define ExtFileSize                 (ExtInodesPerGroup + 4)
#define ExtFileSizeState            (ExtFileSize + 4)
#define ExtFileAddress              (ExtFileSizeState + 4)

#define ExtReadInodeGroup           (ExtFileAddress + 4)
#define ExtReadInodeIndex           (ExtReadInodeGroup + 4)
#define ExtReadInodeGroupBlock      (ExtReadInodeIndex + 4)
#define ExtReadInodeIndexBlock      (ExtReadInodeGroupBlock + 4)
#define ExtReadInodeGroupOffset     (ExtReadInodeIndexBlock + 4)
#define ExtReadInodeIndexOffset     (ExtReadInodeGroupOffset + 2)

#define BootPartition               (BootDrive + 506)

#define ExtReadBlock                word ptr ss:[bp-ExtReadBlockOffset]
#define ExtReadInode                word ptr ss:[bp-ExtReadInodeOffset]
#define DisplayItAndReboot          word ptr ss:[bp-DisplayItAndRebootOffset]
#define PutChars                    word ptr ss:[bp-PutCharsOffset]

#endif
