; PRODBYSIMO FOURCC SCANNER (Win64 / NASM)

extern CreateFileA
extern ReadFile
extern SetFilePointer
extern GetFileSize
extern CloseHandle
extern GetStdHandle
extern WriteFile
extern ExitProcess
extern GetLastError
extern GetCommandLineA

section .data
    STD_OUTPUT_HANDLE equ -11
    GENERIC_READ equ 0x80000000
    FILE_SHARE_READ equ 1
    OPEN_EXISTING equ 3
    FILE_ATTRIBUTE_NORMAL equ 0x80
    
    buffer times 4 db 0
    output times 256 db 0
    filename times 260 db 0
    hex_table db "0123456789ABCDEF"
    bytes_read dd 0
        
    usage db "Usage: fourcc.exe <filename>",13,10,0
    usage_len equ $ - usage - 1
            
    size_prefix db "File size: 0x",0
    size_prefix_len equ $ - size_prefix - 1
    
    size_suffix db " bytes",13,10,0
    size_suffix_len equ $ - size_suffix - 1
        
    error_open db "ERROR: Cannot open file! Error code: 0x",0
    error_open_len equ $ - error_open - 1
    
    newline db 13,10,0
    newline_len equ $ - newline - 1

section .text
global Start

Start:
    sub rsp, 88

    mov rcx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov r15, rax

    call GetCommandLineA
    mov rsi, rax

    call .parse_cmdline
    test rax, rax
    jnz .have_filename

    mov rcx, r15
    mov rdx, usage
    mov r8d, usage_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile
    
    mov rcx, 1
    call ExitProcess

.have_filename:
    call .print_filename

    mov rcx, r15
    mov rdx, newline
    mov r8d, newline_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    mov rcx, filename
    mov edx, GENERIC_READ
    mov r8d, FILE_SHARE_READ
    xor r9d, r9d
    mov qword [rsp+32], OPEN_EXISTING
    mov qword [rsp+40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp+48], 0
    call CreateFileA
    mov r12, rax

    cmp r12, -1
    jne .file_opened

    mov rcx, r15
    mov rdx, error_open
    mov r8d, error_open_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    call GetLastError
    call .print_hex32

    mov rcx, r15
    mov rdx, newline
    mov r8d, newline_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    mov rcx, 1
    call ExitProcess

.file_opened:
    mov rcx, r12
    xor rdx, rdx
    call GetFileSize
    mov r13, rax

    mov rcx, r15
    mov rdx, size_prefix
    mov r8d, size_prefix_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    mov rax, r13
    call .print_hex32

    mov rcx, r15
    mov rdx, size_suffix
    mov r8d, size_suffix_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    xor rbx, rbx        
    xor r14, r14   

.loop:
    lea rax, [rbx+4]
    cmp rax, r13
    jg .done

    mov rcx, r12
    mov rdx, rbx
    mov r8d, 0          
    mov r9d, 0
    call SetFilePointer

    mov rcx, r12
    mov rdx, buffer
    mov r8d, 4
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call ReadFile

    cmp dword [bytes_read], 4
    jne .skip

    mov rsi, buffer
    mov rcx, 4
.check_uppercase:
    mov al, [rsi]
    cmp al, 'A'         
    jb .skip
    cmp al, 'Z'        
    ja .skip
    inc rsi
    dec rcx
    jnz .check_uppercase

    call .print_found_fourcc
    inc r14

.skip:
    inc rbx
    jmp .loop

.done:
    mov rcx, r12
    call CloseHandle
    xor rcx, rcx
    call ExitProcess

.parse_cmdline:
    push rbx
    push rcx
    push rdx
    push rdi

.find_first_space:
    mov al, [rsi]
    test al, al
    jz .no_filename
    inc rsi
    cmp al, ' '
    jne .find_first_space

.skip_spaces2:
    mov al, [rsi]
    cmp al, ' '
    jne .copy_filename
    inc rsi
    jmp .skip_spaces2

.copy_filename:
    test al, al
    jz .no_filename
    
    mov rdi, filename
    xor rcx, rcx
	
.copy_loop:
    mov al, [rsi+rcx]
    test al, al
    jz .end_copy2
    cmp al, ' '
    je .end_copy2
    mov [rdi+rcx], al
    inc rcx
    cmp rcx, 259
    jl .copy_loop

.end_copy2:
    mov byte [rdi+rcx], 0
    mov rax, 1
    jmp .parse_done

.no_filename:
    mov rax, 0
.parse_done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

.print_filename:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi

    mov rsi, filename
    xor rbx, rbx
.count_chars:
    cmp byte [rsi+rbx], 0
    je .got_length
    inc rbx
    jmp .count_chars

.got_length:
    mov rcx, r15
    mov rdx, filename
    mov r8, rbx
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.print_found_fourcc:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    sub rsp, 48       

    mov rsi, buffer
    mov rdi, 4
.print_char:
    movzx rax, byte [rsi]
    mov [output], al
    
    mov rcx, r15
    mov rdx, output
    mov r8d, 1
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile
    
    inc rsi
    dec rdi
    jnz .print_char

    mov byte [output], ' '
    mov byte [output+1], '@'
    mov byte [output+2], ' '
    mov byte [output+3], '0'
    mov byte [output+4], 'x'
    mov rcx, r15
    mov rdx, output
    mov r8d, 5
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    mov rax, rbx
    call .print_hex32

    mov rcx, r15
    mov rdx, newline
    mov r8d, newline_len
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    add rsp, 48
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

.print_hex32:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    sub rsp, 48

    mov rbx, rax       
    mov rdi, output
    mov rcx, 8
.hex32_loop:
    mov rax, rbx
    shr rax, 28
    and rax, 0x0F
    mov rsi, hex_table
    mov al, [rsi+rax]
    mov [rdi], al
    inc rdi
    shl rbx, 4
    dec rcx
    jnz .hex32_loop

    mov rcx, r15
    mov rdx, output
    mov r8d, 8
    lea r9, [bytes_read]
    mov qword [rsp+32], 0
    call WriteFile

    add rsp, 48
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret