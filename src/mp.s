; =============================================================================
; R.C. Pro-Am (USA, Rev 1) - simultaneous 2 player add-on
;
; Everything in this file is new code.  It is stored in two extra 4KB CHR-ROM
; banks appended to the cartridge and copied into the 8KB PRG-RAM at $6000 by
; a tiny loader (see LOADER segment) when the console is reset.  The original
; program enters it through 7 "jsr"/"jmp" hooks patched into the original
; PRG-ROM (see build.py for the list).
;
; Player 2 drives the car in object slot 1 (normally a CPU car).  It runs the
; game's own player-car code: before slot 1's update the per-car state of
; slots 0 and 1 (and their projectile slots 4 and 5) is swapped, together with
; the player-only globals (input, steering, upgrades, ammo), the player
; handler is called as if it were slot 0, and everything is swapped back.
;
; The screen follows whichever human is further ahead; a human that stays
; off-screen is pulled forward to a spot the leader drove over a moment ago.
; =============================================================================

P2S          = 1                ; object slot driven by player 2

; ---- original game RAM ------------------------------------------------------
ppuctrl_sh   = $00
frame_ctr    = $09
mode         = $0D
handler_vec  = $1E              ; jmp ($1E) vector used by the object loop
pad_held     = $27
pad_new      = $28
steer        = $2B              ; lo nibble direction counter, hi=$F0 if B held
spr_next     = $26              ; next free sprite list entry
obj_idx      = $2C
cam_x        = $32              ; 16 bit screen-x of camera
cam_xs       = $34              ; cam_x + 4
cam_y        = $36
cam_ys       = $38
qual_pos     = $52              ; worst qualifying position (0 based)
blink_ctr    = $53
race_pos     = $5C              ; 4 bytes, position of each car (0 = 1st)
near_dist    = $6E
near_idx     = $6F
turbo_t      = $72
oam          = $0200
spr_list     = $0300            ; 9 bytes per entry
real_game    = $03F6            ; 0 in the attract demo
last_dir     = $03FF
music_ch     = $040B            ; bit 7 set while the start music plays
total_laps   = $044E
race_over    = $0450
upgrades     = $0453            ; 3 bytes (tires, turbo, engine)
ammo         = $0459
weapon       = $045A
continues    = $045B

o_state      = $0474            ; arrays with one entry per object (40)
o_xl         = $049C
o_yl         = $04C4
o_xh         = $04EC
o_yh         = $0514
o_sector     = $053C
o_flags      = $0564
o_timer      = $058C
c_prog0      = $05B4            ; arrays with one entry per car (4)
c_flash      = $05B8
o_xf         = $05BC            ; arrays with 8 entries (cars + projectiles)
o_yf         = $05C4
o_head       = $05CC
c_headd      = $05D4
c_speedf     = $05D8
o_speed      = $05DC
c_slidef     = $05E4
c_slide      = $05E8
c_bounce     = $05EC
c_bounced    = $05F0
c_spin       = $05F4
c_prog1      = $05F8
c_laps       = $05FC

; ---- original game routines -------------------------------------------------
SetCHR0      = $FF9D
SetCHR1      = $FFB1
Reset_cont   = $A10C            ; routine the loader hook replaced
SteerTable   = $9E9A
DrawTag      = $93B9
DrawSprites  = $EC6A
DrawCarOnly  = $B1A9
TitleEnd     = $91B6
Pause        = $9D54            ; what START does during a race
AddScore     = $94D4            ; A = tens, Y = thousands (BCD-like pairs)
PlaySfx      = $C4B9

; -----------------------------------------------------------------------------
.segment "LOADER"
; Called with "jsr" from $8028 (in place of "jsr $A10C").  The PPU has been
; warmed up and rendering is off.  Copies CHR banks 8+9 to $6000-$7FFF.
loader:
        lda #8
        jsr SetCHR0
        lda #9
        jsr SetCHR1
        bit $2002
        ldy #0
        sty $2006
        sty $2006
        lda $2007               ; prime the read buffer
        sty $10
        lda #$60
        sta $11
@copy:  lda $2007
        sta ($10),y
        iny
        bne @copy
        inc $11
        bpl @copy               ; stop when the pointer reaches $8000
        jmp boot

; -----------------------------------------------------------------------------
.segment "CODE"

boot:
        lda #0
        jsr SetCHR0
        lda #1
        jsr SetCHR1
        lda #0
        sta twop
        sta in_p2
        jsr set_dispatch
        jsr make_title_text
        jmp Reset_cont

; ---- helpers ------------------------------------------------------------------
; 1 player games must run exactly as before, down to the CPU cycle.  The hooks
; that run during a race (before the HUD split) therefore cost a multiple of 8
; extra cycles in a 1 player game: the game polls for the sprite 0 hit with an
; 8 cycle loop, so the split and everything after it happen on the same cycle
; as in the unpatched game.  PAD n burns n cycles without touching the flags.
.macro PAD n
  .if n = 1 || n < 0
        .error "PAD"
  .endif
  .if n .mod 2 = 1
        jmp :+
:
  .endif
  .repeat n / 2 - (n .mod 2)
        nop
  .endrepeat
.endmacro

; Z clear (A != 0) when a 2 player race is running (never in the demo)
active:
        lda twop
        and real_game
        rts

; =============================================================================
; Title screen
; =============================================================================
; The title screen prints a list of strings every frame ($9281: PPU address,
; text, 0 - and a final 0).  Instead of the game's "FOR 1 PLAYER" it prints a
; menu below "PUSH START":
;
;       1 PLAYER
;       2 PLAYERS
;
; The selected line blinks (the title font has no cursor symbol).
MENU_1P = $226B
MENU_2P = $22AB
menu_1p:   .byte "1 PLAYER "
menu_2p:   .byte "2 PLAYERS"
MENU_LEN = 9

; build the strings in title_text for the current choice and blink phase
make_title_text:
        ldx #0
        lda #>MENU_1P
        sta title_text,x
        lda #<MENU_1P
        sta title_text+1,x
        lda #0                  ; 1 player line: blank it when it is the
        jsr menu_line           ; selection and the blink is off
        lda #>MENU_2P
        sta title_text,x
        lda #<MENU_2P
        sta title_text+1,x
        lda #1
        jsr menu_line
        ldy #0                  ; colour the 2 PLAYERS line like 1 PLAYER
@attr:  lda menu_attr,y
        sta title_text,x
        inx
        iny
        cpy #MENU_ATTR_LEN
        bcc @attr
        rts

; Attribute bytes for the rows the 2 PLAYERS line is on (rows 20-23, columns
; 8-19): upper half palette 3 like the rows above, lower half palette 2 as
; before.  The print routine converts characters to tiles (c - $33 here), so
; $E2 is written as $AF.  Ends the string list.
menu_attr: .byte $23,$EA,$E2,$E2,$E2,0,0
MENU_ATTR_LEN = 7

; A = line (0/1), X = buffer offset of its address; adds text and the 0
menu_line:
        inx
        inx
        cmp twop
        bne @show
        lda frame_ctr
        and #$18                ; blink: hidden 8 frames out of 32
        bne @show
        ldy #MENU_LEN
        lda #' '
@blank: sta title_text,x
        inx
        dey
        bne @blank
        beq @end
@show:  ldy #0
        cpx #2                  ; which line is it?
        bne @two
@one:   lda menu_1p,y
        sta title_text,x
        inx
        iny
        cpy #MENU_LEN
        bcc @one
        bcs @end
@two:   lda menu_2p,y
        sta title_text,x
        inx
        iny
        cpy #MENU_LEN
        bcc @two
@end:   lda #0
        sta title_text,x
        inx
        rts

; hook at $D120, the end of the title screen frame (replaces "jmp $91B6")
h_title:
        jsr read_p2
        lda continues
        bne @end                ; "FOR CONTINUE" screen: keep the choice
        lda p2new
        and #$10                ; START on controller 2: 2 players
        beq @pad1
        lda #1
        bne @set
@pad1:  lda pad_new
        and #$20                ; SELECT on controller 1: other choice
        beq @updown
        lda twop
        eor #1
        jmp @set
@updown:
        lda pad_new
        and #$08                ; up: 1 player
        beq @down
        lda #0
        beq @set
@down:  lda pad_new
        and #$04                ; down: 2 players
        beq @text
        lda #1
@set:   sta twop
        jsr set_dispatch
@text:  jsr make_title_text
@end:   jmp TitleEnd

; =============================================================================
; Controller 2.  The game only reads controller 1 (at $9E30, late in the frame
; where there is no spare CPU time), so controller 2 is strobed and read by
; this routine early in the frame and turned into the same held / pressed /
; steering values the game derives for controller 1.
; =============================================================================
read_p2:
        ldx #1
        stx $4016
        dex
        stx $4016
        ldx #8
@bit:   lda $4017
        lsr a
        rol p2raw
        dex
        bne @bit
        lda p2raw
        tax
        eor p2held
        stx p2held
        and p2raw
        sta p2new
        ; steering, exactly like the routine at $9E50
        lda p2held
        ror a
        bcs @right
        ror a
        bcs @left
        lda ppuctrl_sh
@join:  clc
        adc p2steer
        and #$0F
        sta p2steer
        lda p2held
        and #$40
        beq @nob
        lda p2steer
        ora #$F0
        sta p2steer
@nob:   rts
@right: lda frame_ctr
        and #7
        tay
        lda SteerTable,y
        jmp @join
@left:  lda frame_ctr
        and #7
        tay
        lda #0
        sec
        sbc SteerTable,y
        jmp @join

; =============================================================================
; Object dispatcher (hook at $9BBF: "jsr $8068" -> "jsr h_dispatch" for cars
; 0-3; $8068 is "jmp ($001E)").  In a 1 player game h_dispatch is that very
; instruction, so the cars are updated without a single extra cycle (this
; matters: the race-end code jumps away from inside the player's update).
; For 2 players the instruction is rewritten into a jump to dispatch2p.
; =============================================================================
h_dispatch:
        jmp (handler_vec)

set_dispatch:
        lda twop
        bne @two
        lda #$6C                ; jmp ($001E)
        sta h_dispatch
        lda #<handler_vec
        sta h_dispatch+1
        lda #>handler_vec
        sta h_dispatch+2
        rts
@two:   lda #$4C                ; jmp dispatch2p
        sta h_dispatch
        lda #<dispatch2p
        sta h_dispatch+1
        lda #>dispatch2p
        sta h_dispatch+2
        rts

dispatch2p:
        lda real_game
        beq @near               ; attract demo
        cpx #0
        bne @notp1
        lda spr_next            ; where player 1's car sprite will go
        sta p1_entry
        lda o_state+P2S         ; first frame of a race: car 1 still has
        and #$FC                ; the CPU state the game gave it
        cmp #4
        beq @near
        jsr race_init
        ldx #0
@near:  jmp (handler_vec)
@notp1: cpx #P2S
        bne @near
        jsr read_p2
        lda cam_xs              ; camera as player 1's update left it
        sta csx
        lda cam_xs+1
        sta csx+1
        lda cam_ys
        sta csy
        lda cam_ys+1
        sta csy+1
        ldx #P2S
        lda #$FF
        sta p2_entry
        lda o_state+P2S
        cmp #4
        beq @idle               ; waiting for the start / race finished
        and #$FC
        cmp #4
        bne @orig
        lda spr_next
        sta p2_entry
        jsr swap_in
        lda o_state+4           ; player 1's missile / explosion slot: keep a
        sta snap_state          ; copy if it is in use (player 2's update
        beq @free               ; puts anything it starts there)
        jsr snap_proj
@free:  ldx #0
        stx obj_idx
        inc in_p2
        jsr @orig
        dec in_p2
        lda o_state+4
        cmp snap_state
        bne @spawn
        cmp #0
        beq @back
        lda o_xl+4
        cmp snap_buf+1
        bne @spawn
        lda o_yl+4
        cmp snap_buf+2
        beq @back
@spawn: jsr move_proj           ; it is player 2's: to slot 4+P2S
        lda snap_state
        beq @back
        jsr unsnap_proj         ; and player 1's back
@back:  jsr swap_out
        lda cam_xs              ; camera as player 2's update left it
        sta csx+2
        lda cam_xs+1
        sta csx+3
        lda cam_ys
        sta csy+2
        lda cam_ys+1
        sta csy+3
        jsr update_camera       ; the real camera, before the CPU cars draw
        ldx #P2S
        stx obj_idx
        rts
@idle:  jsr update_camera
        ldx #P2S
        jmp DrawCarOnly
@orig:  jmp (handler_vec)

.macro XCHG a1, a2
        lda a1
        ldy a2
        sta a2
        sty a1
.endmacro

.macro XCAR base
        XCHG base, base+P2S
.endmacro

.macro XOBJ base
        XCHG base, base+P2S
        XCHG base+4, base+4+P2S
.endmacro

; The car's own entries.  Only what the player code uses is exchanged (not the
; CPU-only arrays, race progress or the timer array) to save CPU time: there
; is little to spare before the HUD split.
swap_objects:
        XCAR o_state
        XCAR o_xl
        XCAR o_yl
        XCAR o_xh
        XCAR o_yh
        XCAR o_sector
        XCAR o_flags
        XCAR o_xf
        XCAR o_yf
        XCAR o_head
        XCAR o_speed
        XCAR c_flash
        XCAR c_headd
        XCAR c_speedf
        XCAR c_slidef
        XCAR c_slide
        XCAR c_bounce
        XCAR c_bounced
        XCAR c_spin
        XCAR $0604              ; top speed, worked out by the player code
        ; player-only globals
        XCHG pad_held, p2held
        XCHG pad_new, p2new
        XCHG steer, p2steer
        XCHG last_dir, p2lastdir
        XCHG upgrades, p2upg
        XCHG upgrades+1, p2upg+1
        XCHG upgrades+2, p2upg+2
        XCHG ammo, p2ammo
        XCHG weapon, p2weap
        XCHG turbo_t, p2turbo
        rts

; Copy of player 1's missile / explosion slot (4)
.macro PRJ_ARRAYS op
        op o_state, 0
        op o_xl, 1
        op o_yl, 2
        op o_xh, 3
        op o_yh, 4
        op o_sector, 5
        op o_flags, 6
        op o_timer, 7
        op o_xf, 8
        op o_yf, 9
        op o_head, 10
        op o_speed, 11
.endmacro
.macro SNAP base, i
        lda base+4
        sta snap_buf+i
.endmacro
.macro UNSNAP base, i
        lda snap_buf+i
        sta base+4
.endmacro
snap_proj:
        PRJ_ARRAYS SNAP
        rts
unsnap_proj:
        PRJ_ARRAYS UNSNAP
        rts

; a missile / explosion player 2's car started went into slot 4: move it
.macro MPRJ base
        lda base+4
        sta base+4+P2S
.endmacro
move_proj:
        MPRJ o_state
        MPRJ o_xl
        MPRJ o_yl
        MPRJ o_xh
        MPRJ o_yh
        MPRJ o_sector
        MPRJ o_flags
        MPRJ o_timer
        MPRJ o_xf
        MPRJ o_yf
        MPRJ o_head
        MPRJ o_speed
        lda #0
        sta o_state+4
        rts

swap_in:
        lda blink_ctr
        sta sv_blink
        lda near_dist
        sta sv_near
        lda near_idx
        sta sv_near+1
        jmp swap_objects

swap_out:
        jsr swap_objects
        lda sv_blink
        sta blink_ctr
        lda sv_near
        sta near_dist
        lda sv_near+1
        sta near_idx
        rts

; =============================================================================
; Camera.  The player car code has just centred it on player 1 ($A748); in a
; 2 player game it is moved to follow the leading human instead, at most a
; few pixels per frame so that the nametable streaming keeps up.
; =============================================================================
CAM_MAXX = 8
CAM_MAXY = 6

update_camera:
        ldx leader
        ; target screen position of the leader (same maths as $A748)
        lda o_xf,x
        sec
        sbc o_yf,x
        lda o_xl,x
        sbc o_yl,x
        sta tmp0
        lda o_xh,x
        sbc o_yh,x
        clc
        adc #4
        sta tmp1
        lda tmp0
        sec
        sbc #$80
        sta tx
        lda tmp1
        sbc #0
        sta tx+1
        lda o_xf,x
        clc
        adc o_yf,x
        lda o_xl,x
        adc o_yl,x
        sta tmp0
        lda o_xh,x
        adc o_yh,x
        sta tmp1
        rol a
        ror tmp1
        ror tmp0
        lda tmp0
        sec
        sbc #$5C
        sta ty
        lda tmp1
        sbc #0
        sta ty+1
        lda cam_ok
        bne @smooth
        lda tx
        sta camx
        lda tx+1
        sta camx+1
        lda ty
        sta camy
        lda ty+1
        sta camy+1
        lda #1
        sta cam_ok
        jmp cam_store
@smooth:
        ; x
        lda tx
        sec
        sbc camx
        sta tmp0
        lda tx+1
        sbc camx+1
        ldy #CAM_MAXX
        jsr clamp
        clc
        adc camx
        sta camx
        txa
        adc camx+1
        sta camx+1
        ; y
        lda ty
        sec
        sbc camy
        sta tmp0
        lda ty+1
        sbc camy+1
        ldy #CAM_MAXY
        jsr clamp
        clc
        adc camy
        sta camy
        txa
        adc camy+1
        sta camy+1
cam_store:
        lda camx
        sta cam_x
        clc
        adc #4
        sta cam_xs
        lda camx+1
        sta cam_x+1
        adc #0
        sta cam_xs+1
        lda camy
        sta cam_y
        clc
        adc #4
        sta cam_ys
        lda camy+1
        sta cam_y+1
        adc #0
        sta cam_ys+1
        rts

; A:tmp0 = signed 16 bit difference, Y = limit.
; returns A = clamped low byte, X = sign extension ($00/$FF)
clamp:
        ora #0
        bmi @neg
        bne @pos_lim            ; >= 256
        lda tmp0
        sty tmp1
        cmp tmp1
        bcc @pos_ok
@pos_lim:
        tya
@pos_ok:
        ldx #0
        rts
@neg:   cmp #$FF
        bne @neg_lim
        lda tmp0
        sty tmp1
        clc
        adc tmp1                ; diff + limit
        bcc @neg_lim            ; diff < -limit
        lda tmp0
        ldx #$FF
        rts
@neg_lim:
        sty tmp1
        lda #0
        sec
        sbc tmp1
        ldx #$FF
        rts

;=============================================================================
; Player car sprites.  The game draws the player's car at the centre of the
; screen and gives it palette 0; with two players the cars can be anywhere,
; so before the sprites are drawn the entries of both human cars are given
; their real screen position (like the CPU cars'), player 2's car gets its
; own palette and owner, and the positions are kept for the tags.
; X = car slot (0 / P2S), Y = sprite list entry or $FF for none.
; =============================================================================
; The player code drew the car relative to the camera it set itself (saved in
; csx/csy, 2 bytes per player); move it to the real camera.  X = 0 / P2S,
; Y = sprite list entry.  (Cheaper than place_car.)
shift_car:
        txa
        asl a
        tax
        lda csx,x
        sec
        sbc cam_xs
        sta tmp0
        lda csx+1,x
        sbc cam_xs+1
        sta tmp1
        lda spr_list+2,y
        clc
        adc tmp0
        sta tmp2                ; screen x
        lda spr_list+3,y
        adc tmp1
        sta tmp3
        lda csy,x
        sec
        sbc cam_ys
        sta tmp0
        lda csy+1,x
        sbc cam_ys+1
        sta tmp1
        txa
        lsr a
        tax
        lda spr_list+4,y
        clc
        adc tmp0
        sta tmp0                ; screen y
        lda spr_list+5,y
        adc tmp1
        sta tmp1
        jmp place_y

place_car:
        lda o_xf,x
        sec
        sbc o_yf,x
        lda o_xl,x
        sbc o_yl,x
        sta tmp0
        lda o_xh,x
        sbc o_yh,x
        clc
        adc #4
        sta tmp1
        lda tmp0
        sec
        sbc cam_xs
        sta tmp2                ; screen x
        lda tmp1
        sbc cam_xs+1
        sta tmp3
        lda o_xf,x
        clc
        adc o_yf,x
        lda o_xl,x
        adc o_yl,x
        sta tmp0
        lda o_xh,x
        adc o_yh,x
        sta tmp1
        rol a
        ror tmp1
        ror tmp0
        lda tmp0
        sec
        sbc cam_ys
        sta tmp0                ; screen y
        lda tmp1
        sbc cam_ys+1
        sta tmp1
place_y:
        lda tmp1
        beq @y_ok
        lda #1                  ; off the top or bottom
        sta tmp3
@y_ok:  cpy #$FF
        beq @tag
        lda tmp2
        sta spr_list+2,y
        lda tmp3
        sta spr_list+3,y        ; not 0: not drawn
        lda tmp0
        sta spr_list+4,y
        lda tmp1
        sta spr_list+5,y
@tag:   lda tmp3
        bne @off
        lda tmp0
        cmp #$B8
        bcs @off
        lda #1
        sta pvis,x
        lda tmp2
        sta psx,x
        lda tmp0
        sta psy,x
        rts
@off:   lda #0
        sta pvis,x
        rts

; hook at $9D74 in the pause screen ("lda #0 / jsr $FF9D" -> "jsr h_pause"):
; START on controller 2 counts as START.  The 1 player path costs 24 extra
; cycles, a multiple of 8 (the pause frame also waits for the sprite 0 hit).
h_pause:
        lda #0
        jsr SetCHR0
        lda twop
        bne @two
        nop
        rts
@two:   jsr read_p2
        lda p2new
        and #$10
        ora pad_new
        sta pad_new
        rts

; =============================================================================
; Once per frame after all objects moved (hook at $9BF5, replaces the call
; to the position tag routine).
; =============================================================================
h_frame:
        PAD 7
        jsr active
        bne @two
        jmp DrawTag
@two:   lda sector_swap         ; give player 1's sector back (see h_finish)
        beq @tags
        lda sv_sector
        sta o_sector
        lda #0
        sta sector_swap
@tags:  jsr DrawTag             ; tag tiles for player 1
        lda race_over
        beq @racing
        ; Race over: the game decides with $5C whether to continue.  With
        ; two humans the better one counts, but (as in 1 player) at least one
        ; CPU car must be beaten: 3rd place then means both CPU cars are
        ; ahead, which is out.
        ; The places are exchanged, not overwritten: the next race puts the
        ; cars on the grid by place, so every car must keep its own.  The
        ; game recomputes player 1's place every frame, so this always
        ; starts from the final places, saved once.
        lda pos_saved
        bne @restore
        inc pos_saved
        ldx #3
@save:  lda race_pos,x
        sta final_pos,x
        dex
        bpl @save
@restore:
        ldx #3
@rest:  lda final_pos,x
        sta race_pos,x
        dex
        bpl @rest
        jsr best_pos
        cmp #2
        bcc @keep
        lda #3
@keep:  ldx #3
@find:  cmp race_pos,x
        beq @swap
        dex
        bpl @find
        rts
@swap:  ldy race_pos
        sta race_pos
        sty race_pos,x
        rts
@racing:
        lda p2new               ; START on controller 2 pauses too
        and #$10
        beq @nopause
        jmp Pause
@nopause:
        bit $2002               ; running late (HUD split already reached)?
        bvs @late               ; then leave the rest for the next frame
        lda frame_ctr           ; spread the bookkeeping over two frames
        lsr a
        bcs @odd
        jsr calc_p2pos
        lda p2pos
        asl a
        clc
        adc #$E9
        sta p2tag_tile
        jmp p2_lap_bonus
@odd:   jsr update_leader
        jmp pull_along
@late:  rts

; Lap bonuses for player 2, like the game gives player 1 ($A9DD): 25 points
; every half lap, 100 points and a jingle for a full lap.
p2_lap_bonus:
        lda c_laps+P2S
        cmp p2_laps
        beq @half
        bcc @set
        lda #$0A
        jsr PlaySfx
        lda #0
        ldy #1
        jsr AddScore
        jmp @set
@half:  lda c_prog1+P2S
        cmp p2_prog
        beq @set
        bcc @set                ; going backwards
        and #1
        bne @set
        lda #$19
        ldy #0
        jsr AddScore
@set:   lda c_laps+P2S
        sta p2_laps
        lda c_prog1+P2S
        sta p2_prog
        rts

; position (0..3) of player 2's car, counted like the game does for player 1
calc_p2pos:
        lda #0
        sta p2pos
        ldy #0
@loop:  cpy #P2S
        beq @next
        lda c_prog0+P2S
        sec
        sbc c_prog0,y
        lda c_prog1+P2S
        sbc c_prog1,y
        lda c_laps+P2S
        sbc c_laps,y
        bcs @next
        inc p2pos
@next:  iny
        cpy #4
        bcc @loop
        rts

; carry set when slot X (0 or P2S) is ahead of or level with the other human
; (uses Y)
leader_cmp:
        lda c_prog0,x
        sec
        sbc c_prog0,y
        lda c_prog1,x
        sbc c_prog1,y
        lda c_laps,x
        sbc c_laps,y
        rts

update_leader:
        ldx #0
        ldy #P2S
        jsr leader_cmp
        lda #0
        bcs @set
        lda #P2S
@set:   sta leader
        rts

; ---- pull-along --------------------------------------------------------------
HIST_N    = 32                  ; ring buffer size (power of two)
HIST_BACK = 7                   ; entries (2 frames each) behind the leader
OFF_LIMIT = 10                  ; checks (every 2nd frame) off-screen first

pull_along:
        lda race_over
        bne @exit
        lda music_ch
        bpl @go                 ; bit 7: start not given yet
@exit:  rts
@go:
        ; record the leader's position
        ldx leader
        ldy hist_pos
        lda o_xl,x
        sta h_xl,y
        lda o_xh,x
        sta h_xh,y
        lda o_xf,x
        sta h_xf,y
        lda o_yl,x
        sta h_yl,y
        lda o_yh,x
        sta h_yh,y
        lda o_yf,x
        sta h_yf,y
        lda o_head,x
        sta h_hd,y
        lda o_sector,x
        sta h_sec,y
        lda c_prog0,x
        sta h_p0,y
        lda c_prog1,x
        sta h_p1,y
        lda c_laps,x
        sta h_lap,y
        iny
        tya
        and #HIST_N-1
        sta hist_pos
        lda hist_cnt
        cmp #HIST_N
        bcs @full
        inc hist_cnt
@full:
        ; the human that is not leading
        lda leader
        eor #P2S
        tax
        lda pvis,x
        bne @onscreen
        lda o_state,x
        cmp #5                  ; only while driving normally
        bne @noop
        inc off_cnt
        lda off_cnt
        cmp #OFF_LIMIT
        bcc @noop
        lda hist_cnt
        cmp #HIST_BACK+1
        bcc @noop
        jmp warp
@onscreen:
        lda #0
        sta off_cnt
@noop:  rts

; move car X to the spot the leader occupied HIST_BACK frames ago
warp:
        lda #0
        sta off_cnt
        lda hist_pos
        sec
        sbc #HIST_BACK+1
        and #HIST_N-1
        tay
        lda h_xl,y
        sta o_xl,x
        lda h_xh,y
        sta o_xh,x
        lda h_xf,y
        sta o_xf,x
        lda h_yl,y
        sta o_yl,x
        lda h_yh,y
        sta o_yh,x
        lda h_yf,y
        sta o_yf,x
        lda h_hd,y
        sta o_head,x
        sta c_headd,x
        lda h_sec,y
        sta o_sector,x
        lda h_p0,y
        sta c_prog0,x
        lda h_p1,y
        sta c_prog1,x
        lda h_lap,y
        sta c_laps,x
        lda #0
        sta c_speedf,x
        sta o_speed,x
        sta c_slidef,x
        sta c_slide,x
        sta c_bounce,x
        sta c_spin,x
        cpx #0
        bne @p2
        lda steer               ; keep the steering counters in step
        and #$0F
        sta last_dir
        rts
@p2:    lda p2steer
        and #$0F
        sta p2lastdir
        lda c_laps+P2S          ; no lap bonus for being pulled along
        sta p2_laps
        lda c_prog1+P2S
        sta p2_prog
        rts

; hook at $9BF8 (replaces "jsr $EC6A", which draws the sprite list)
h_oam:
        PAD 7
        jsr active
        bne @two
        jmp DrawSprites
@two:   bit $2002               ; HUD split reached already (an unusually
        bvc @intime             ; busy frame)?  Then keep last frame's sprites
        rts                     ; so the split is not delayed any further.
@intime:
        ldx #0
        ldy p1_entry
        jsr shift_car
        ldx #P2S
        ldy p2_entry
        cpy #$FF
        bne @p2act
        jsr place_car           ; waiting / finished: drawn like a CPU car
        jmp @tag1
@p2act: jsr shift_car
        ldy p2_entry
        lda #P2S                ; player 2's car: own palette and owner
        sta spr_list+7,y
        lda spr_list+6,y
        and #$FC
        sta tmp0
        lda spr_list+6,y
        clc
        adc #P2S
        and #3
        ora tmp0
        sta spr_list+6,y
@tag1:  ; player 1's tag (sprites 1 and 2) follows player 1's car
        lda pvis
        beq @hide1
        lda psy
        sec
        sbc #$20
        bcc @hide1
        sta oam+4
        sta oam+8
        lda psx
        sec
        sbc #4
        bcc @hide1
        sta oam+7
        clc
        adc #8
        bcs @hide1
        sta oam+11
        jmp @draw
@hide1: lda #$F8
        sta oam+4
        sta oam+8
@draw:  jsr DrawSprites
        ; player 2's tag goes into the last two sprites
        lda pvis+1
        beq @hide2
        lda psy+1
        sec
        sbc #$20
        bcc @hide2
        sta oam+$F8
        sta oam+$FC
        lda psx+1
        sec
        sbc #4
        bcc @hide2
        sta oam+$FB
        clc
        adc #8
        bcs @hide2
        sta oam+$FF
        lda p2tag_tile
        sta oam+$F9
        clc
        adc #1
        sta oam+$FD
        lda #P2S
        sta oam+$FA
        sta oam+$FE
        rts
@hide2: lda #$F8
        sta oam+$F8
        sta oam+$FC
        rts

; =============================================================================
; Race set-up / end
; =============================================================================
; first frame of a 2 player race
race_init:
        lda #4                  ; player 2 takes over car 1
        sta o_state+P2S
        lda #0
        sta pos_saved
        sta cam_ok
        sta off_cnt
        sta hist_cnt
        sta hist_pos
        sta leader
        sta in_p2
        lda #1
        sta pvis
        sta pvis+1
        lda p2steer
        and #$0F
        sta p2lastdir
        lda c_laps+P2S
        sta p2_laps
        lda c_prog1+P2S
        sta p2_prog
        lda $03F9               ; a new vehicle (all letters collected)
        cmp p2veh               ; starts again without upgrades
        beq @same
        sta p2veh
        lda #0
        sta p2upg
        sta p2upg+1
        sta p2upg+2
@same:  lda $044B               ; first race of a new game:
        ora $044C               ; player 2 starts from scratch too
        ora $03E7
        ora $03E8
        ora $03E9
        bne @old
        lda $03F9
        sta p2veh
        lda #0
        sta p2upg
        sta p2upg+1
        sta p2upg+2
        sta p2ammo
        sta p2weap
        sta p2turbo
@old:   rts

; best (lowest) finishing position of the human players
best_pos:
        jsr active
        bne @two
        lda race_pos
        rts
@two:   lda race_pos+P2S
        cmp race_pos
        bcc @done
@one:   lda race_pos
@done:  rts

; hook at $AA31 (replaces "lda $0450"): when the first car finishes, the race
; result is scored with the better placed human
h_finish:
        PAD 6
        jsr active
        bne @two
        lda race_over
        rts
@two:   lda race_over
        bne @done
        ; scenery and items are handled around player 1's sector ($BBD9,
        ; right after this); use the leader's sector until h_frame
        lda o_sector
        sta sv_sector
        ldx leader
        lda o_sector,x
        sta o_sector
        lda #1
        sta sector_swap
        ldx #3
@chk:   lda c_laps,x
        cmp total_laps
        beq @fin
        dex
        bpl @chk
        bmi @done
@fin:   jsr calc_p2pos
        lda p2pos
        cmp race_pos
        bcs @done
        sta race_pos
@done:  lda race_over
        rts

; =============================================================================
.segment "BSS"
title_text:  .res 32          ; first: must not cross a page
twop:        .res 1
in_p2:       .res 1
p2raw:       .res 1
p2held:      .res 1
p2new:       .res 1
p2steer:     .res 1
p2lastdir:   .res 1
p2upg:       .res 3
p2ammo:      .res 1
p2weap:      .res 1
p2turbo:     .res 1
p2veh:       .res 1
sv_blink:    .res 1
sv_near:     .res 2
leader:      .res 1
cam_ok:      .res 1
sv_sector:   .res 1
sector_swap: .res 1
p1_entry:    .res 1
p2_entry:    .res 1
camx:        .res 2
camy:        .res 2
tx:          .res 2
ty:          .res 2
tmp0:        .res 1
tmp1:        .res 1
tmp2:        .res 1
tmp3:        .res 1
pvis:        .res 2
psx:         .res 2
psy:         .res 2
p2pos:       .res 1
pos_saved:   .res 1
final_pos:   .res 4
csx:         .res 4          ; camera after player 1's / player 2's update
csy:         .res 4
snap_state:  .res 1
snap_buf:    .res 12
p2_laps:     .res 1
p2_prog:     .res 1
p2tag_tile:  .res 1
off_cnt:     .res 1
hist_pos:    .res 1
hist_cnt:    .res 1
h_xl:        .res HIST_N
h_xh:        .res HIST_N
h_xf:        .res HIST_N
h_yl:        .res HIST_N
h_yh:        .res HIST_N
h_yf:        .res HIST_N
h_hd:        .res HIST_N
h_sec:       .res HIST_N
h_p0:        .res HIST_N
h_p1:        .res HIST_N
h_lap:       .res HIST_N

.export loader, h_title, h_dispatch, h_frame, h_oam, h_finish, h_pause, title_text
