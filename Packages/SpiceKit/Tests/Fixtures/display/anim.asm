org 0x7c00
bits 16
    cli
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov ax, 0x0013          ; 320x200x256
    int 0x10
    mov ax, 0xA000
    mov es, ax
    xor bp, bp              ; frame counter
.frame:
    xor di, di
    xor dx, dx              ; y
.row:
    xor cx, cx              ; x
.col:
    ; top 64 rows: static checker (same every frame -> GLZ back references)
    cmp dx, 64
    jae .moving
    mov ax, cx
    xor ax, dx
    and al, 0x18
    add al, 32
    jmp .put
.moving:
    mov ax, cx
    add ax, dx
    add ax, bp
    shr ax, 1
    and al, 0x3F
    add al, 64
    cmp cx, 160
    jb .put
    mov ax, dx
    add ax, bp
    and al, 0x0F
    add al, 16
.put:
    stosb
    inc cx
    cmp cx, 320
    jb .col
    inc dx
    cmp dx, 200
    jb .row
    ; wait ~60 ms
    mov ah, 0x86
    xor cx, cx
    mov dx, 60000
    int 0x15
    inc bp
    cmp bp, 40
    jb .frame
.done:
    hlt
    jmp .done
times 510-($-$$) db 0
dw 0xAA55
