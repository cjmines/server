#load "coop.jai";

#import "Basic";
#import "Command_Line";

Arguments :: struct {

    board_width:       s32 = 16;    @"?Width of the game board (default: 16)."
    board_height:      s32 = 16;    @"?Height of the game board (default: 16)."
    mine_count:        s32;         @"?Number of mines to place."
    no_guess_solvable: bool = false; @"?If set, guarantee no-guess solvability."

    id_of_owning_lobby: u32;        @"?The lobby ID that owns this session."

    port : u16; @"?The port to run this server on."

    #place board_width; settings: Coop_Game_Settings;
}

main :: () {

    success, args, is_set := parse_arguments(Arguments);
    if !success exit(1);

    log("got args: %", args);

    if !is_set.mine_count {
        log_error("You must specify -mine_count.\n");
        exit(1);
    }

    if !is_set.port {
        log_error("You must specify -port.\n");
        exit(1);
    }

    if !is_set.id_of_owning_lobby {
        log_error("You must specify -id_of_owning_lobby.\n");
        exit(1);
    }

    run_coop_game_mode(args.settings, args.id_of_owning_lobby, args.port);
}
