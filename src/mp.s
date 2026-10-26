; =============================================================================
; R.C. Pro-Am (USA, Rev 1) - simultaneous 2 player add-on
;
; Everything in this file is new code.  It is stored in two extra 4KB CHR-ROM
; banks appended to the cartridge and copied into the 8KB PRG-RAM at $6000 by
; a tiny loader (see LOADER segment) when the console is reset.  The original
; program is entered from a handful of "jsr"/"jmp" hooks patched into the
; original PRG-ROM (see build.py for the list).
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
ReadPad_cont = $9E35            ; rest of the joypad routine
SteerJoin    = $9E64
SteerTable   = $9E9A
CamOrig      = $A748
DrawTag      = $93B9
DrawSprites  = $EC6A
ItemsNear    = $BBD9
DrawCarOnly  = $B1A9
RaceInit_end = $BA97
NewGame      = $81A2
TitleEnd     = $91B6
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
        jsr make_title_text
        jmp Reset_cont

; ---- helpers ------------------------------------------------------------------
; In a 1 player game every hook must cost a multiple of 8 extra cycles before
; the HUD split: the game polls for the sprite 0 hit with an 8 cycle loop, so
; the split (and everything after it) then happens on exactly the same cycle as
; in the unpatched game.  PAD n burns n cycles without touching the flags.
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
title_1p: .byte $22,$69," FOR 1 PLAYER ",0,0
title_2p: .byte $22,$69,"FOR 2 PLAYERS ",0,0

make_title_text:
        ldx #17
        lda twop
        bne @two
@one:   lda title_1p,x
        sta title_text,x
        dex
        bpl @one
        rts
@two:   lda title_2p,x
        sta title_text,x
        dex
        bpl @two
        rts

; hook at $D120, the end of the title screen frame (replaces "jmp $91B6")
h_title:
        jsr read_p2
        lda continues
        bne @done               ; "FOR CONTINUE" screen: keep the choice
        lda pad_new
        and #$20                ; SELECT on controller 1
        bne @toggle
        lda p2new
        and #$10                ; START on controller 2
        beq @done
@toggle:
        lda twop
        eor #1
        sta twop
        jsr make_title_text
@done:  jmp TitleEnd

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
        and #3
        cmp #1
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
; Object dispatcher (hook at $9BBF, replaces "jsr $8068" for slots 0-3)
; =============================================================================
h_dispatch:
        PAD 2
        jsr active
        bne @two
        jmp (handler_vec)
@two:   cpx #0
        bne @notp1
        lda o_state+P2S         ; first frame of a race: car 1 still has
        and #$FC                ; the CPU state the game gave it
        cmp #4
        beq @orig
        jsr race_init
        ldx #0
        jmp (handler_vec)
@notp1: cpx #P2S
        bne @orig
        jsr read_p2
        ldx #P2S
        lda o_state+P2S
        cmp #4
        beq @idle               ; waiting for the start / race finished
        and #$FC
        cmp #4
        bne @orig
        jsr swap_in
        ldx #0
        stx obj_idx
        inc in_p2
        jsr @orig
        dec in_p2
        jsr swap_out
        ldx #P2S
        stx obj_idx
        rts
@idle:  jmp DrawCarOnly
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

swap_objects:
        XOBJ o_state
        XOBJ o_xl
        XOBJ o_yl
        XOBJ o_xh
        XOBJ o_yh
        XOBJ o_sector
        XOBJ o_flags
        XOBJ o_timer
        XOBJ o_xf
        XOBJ o_yf
        XOBJ o_head
        XOBJ o_speed
        XCAR c_prog0
        XCAR c_flash
        XCAR c_headd
        XCAR c_speedf
        XCAR c_slidef
        XCAR c_slide
        XCAR c_bounce
        XCAR c_bounced
        XCAR c_spin
        XCAR c_prog1
        XCAR c_laps
        XCAR $0600
        XCAR $0604
        XCAR $0608
        XCAR $060C
        XCAR $0610
        XCAR $0614
        XCAR $0618
        XCAR race_pos
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
; Camera (hooks at $B63D and $B491, the calls from the player car code).
; 1 player: original code.  2 players: follow the
; leading human, moving at most a few pixels per frame so that the nametable
; streaming keeps up.
; =============================================================================
CAM_MAXX = 8
CAM_MAXY = 6

h_camera:
        PAD 7
        jsr active
        bne @two
        jmp CamOrig
@two:   lda in_p2
        beq @calc
        rts                     ; player 2's own update: camera untouched
@calc:  stx tmpx
        sty tmpy
        ldx leader
        lda o_sector,x
        sta cam_sector
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
        jmp @store
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
@store: lda camx
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
        ldx tmpx
        ldy tmpy
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

; =============================================================================
; Player car sprite position (hooks at $B645 and $B4A3).
; The original code puts the player car at the centre of the screen; with two
; players the car can be anywhere, so its position is computed like the CPU
; cars'.  Y = sprite list entry, X = object slot (0).
; =============================================================================
h_plsprite:
        PAD 3
        jsr active
        bne @two
        lda #$7C
        sta spr_list+2,y
        lda #$58
        sta spr_list+4,y
        lda #0
        sta spr_list+3,y
        sta spr_list+5,y
        rts
@two:   stx tmpx
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
        sta spr_list+2,y
        sta tmp2
        lda tmp1
        sbc cam_xs+1
        sta spr_list+3,y
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
        sta spr_list+4,y
        sta tmp0
        lda tmp1
        sbc cam_ys+1
        sta spr_list+5,y
        beq @vis_y
        lda #1                  ; off the top/bottom: hide
        sta spr_list+3,y
        sta tmp3
@vis_y: ; remember the screen position for the position tags / pull-along
        ldx in_p2
        lda tmp3
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
        ldx tmpx
        rts
@off:   lda #0
        sta pvis,x
        ldx tmpx
        rts

; hook at $B657: "txa / sta $14" (sprite palette = car slot)
h_pal:
        PAD 2
        jsr slot_of_x
        sta $14
        rts

; hook at $B4BB: "txa / sta $0306,y"
h_pal7:
        PAD 3
        jsr slot_of_x
        sta spr_list+6,y
        rts

; hooks at $B690 and $B4CB: "txa / sta $0307,y" (object owning the sprite)
h_owner:
        jsr slot_of_x
        sta spr_list+7,y
        rts

; A = real object slot of the car being processed
slot_of_x:
        lda in_p2
        bne @p2
        txa
        rts
@p2:    lda #P2S
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
@two:   jsr DrawTag             ; sets up the tag tiles for player 1
        jsr calc_p2pos
        ; player 1 tag follows player 1's car
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
        jmp @tag2
@hide1: lda #$F8
        sta oam+4
        sta oam+8
@tag2:  ; player 2 tag (written to OAM after the sprites, see h_oam)
        lda p2pos
        asl a
        clc
        adc #$E9
        sta p2tag_tile
        lda pvis+1
        beq @hide2
        lda psy+1
        sec
        sbc #$20
        bcc @hide2
        sta p2tag_y
        lda psx+1
        sec
        sbc #4
        bcc @hide2
        sta p2tag_x
        clc
        adc #8
        bcs @hide2
        jmp @lead
@hide2: lda #$F8
        sta p2tag_y
@lead:  lda race_over
        beq @racing
        ; Race over: the game decides with $5C whether to continue.  With
        ; two humans the better one counts, but (as in 1 player) at least one
        ; CPU car must be beaten: 3rd place then means both CPU cars are
        ; ahead, which is out.
        jsr best_pos
        cmp #2
        bcc @keep
        lda #3
@keep:  sta race_pos
        rts
@racing:
        jsr update_leader
        jmp pull_along

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
HIST_BACK = 14                  ; how many frames behind the leader to drop
OFF_LIMIT = 20                  ; frames off-screen before being pulled along

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
        rts

; hook at $9BF8 (replaces "jsr $EC6A"): draw sprites, then player 2's tag
h_oam:
        PAD 6
        jsr DrawSprites
        jsr active
        bne @two
        rts
@two:   lda p2tag_y
        sta oam+$F8
        sta oam+$FC
        lda p2tag_tile
        sta oam+$F9
        clc
        adc #1
        sta oam+$FD
        lda #P2S
        sta oam+$FA
        sta oam+$FE
        lda p2tag_x
        sta oam+$FB
        clc
        adc #8
        sta oam+$FF
        rts

; hook at $9BF2 (replaces "jsr $BBD9"): items/scenery are processed around
; the sector of the car the camera follows
h_items:
        PAD 7
        jsr active
        bne @done
        lda o_sector
        sta cam_sector
@done:  jmp ItemsNear

; =============================================================================
; Race set-up / end
; =============================================================================
; first frame of a 2 player race
race_init:
        lda #4                  ; player 2 takes over car 1
        sta o_state+P2S
        lda #0
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
title_text:  .res 18          ; first: must not cross a page
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
cam_sector:  .res 1
camx:        .res 2
camy:        .res 2
tx:          .res 2
ty:          .res 2
tmp0:        .res 1
tmp1:        .res 1
tmp2:        .res 1
tmp3:        .res 1
tmpx:        .res 1
tmpy:        .res 1
pvis:        .res 2
psx:         .res 2
psy:         .res 2
p2pos:       .res 1
p2tag_x:     .res 1
p2tag_y:     .res 1
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

.export loader, h_title, h_dispatch, h_camera
.export h_plsprite, h_pal, h_pal7, h_owner, h_frame, h_oam, h_items
.export h_finish
.export cam_sector, title_text
