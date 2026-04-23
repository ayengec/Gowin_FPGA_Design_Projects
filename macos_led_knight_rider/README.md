# Tang Primer 20K LED Chaser Smoke Test

This is a minimal project to verify:
- Gowin IDE project opens,
- synthesis/PnR/bitstream generation works,
- download to board works,
- board clock + LEDs are alive.

## Behavior
- 4 LEDs run a Knight Rider style pattern: `0 -> 1 -> 2 -> 3 -> 2 -> 1 -> ...`
- Step period is ~100 ms.

## Files
- `rtl/top_led_chaser.sv`
- `constraints/led_chaser_smoke_test.cst`
- `constraints/led_chaser_smoke_test.sdc`
- `led_chaser_smoke_test.gprj`

## Build (Gowin IDE)
1. Open `led_chaser_smoke_test.gprj`.
2. Go to `Project -> Settings -> Synthesize`.
3. Set **Language** from `Verilog` to `SystemVerilog`, then click **OK**.
4. Run **Synthesize**.
5. Run **Place & Route**.
6. Run **Generate Bitstream**.

## Program (Gowin Programmer)
1. Connect board with USB-C (JTAG/programming side).
2. Open Gowin Programmer.
3. Select cable/device.
4. Load generated `.fs` file.
5. Click **Program/Download**.

## Expected result
- After successful download, LEDs should move continuously.
- If LEDs move, your macOS toolchain + board programming path is verified.
