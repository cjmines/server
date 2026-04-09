Network :: #import "tbx/network";
#import "tbx/engine";
#import "tbx/time";
#import "tbx/serialize";
#import "tbx/temporal_binary_switch";

#import "tbx/section_logger"()(LOGGING=false);

#import "shared";
#import "game_logic";

#import "Hash_Table";
#import "String";
#import "Basic";
Random :: #import "Random";

// todo next step is to import the game logic and start interacting with that on the server as well.

// we also need to create the host program or server host or whatever we want to call it ...

// how this works. Player connects to host, creates a room, disconects from host and joins room
// connecting player has room code connects to host and submits room code.

// in order to go from a room code to the right host we need a third system called the directory server


Server_Coop_Player :: struct {
    using #as coop_player : Coop_Player;
    using #as infrequent_coop_player : Infrequent_Coop_Player;

    multi_open := false;
    multi_flag := false;

    open_tbs := Temporal_Binary_Switch.{state_update_method = .IMMEDIATE};
    flag_tbs := Temporal_Binary_Switch.{state_update_method = .IMMEDIATE};
}


Coop :: struct {
    board : Board;
    host : *Network.Host;
    looping_program : Looping_Program;
    infrequent_send_signal := Periodic_Signal.{frequency_hz = 2};

    game_state : Coop_Game_State;
    game_state_timer : Timer;

    messages_to_send_out : [..] string;

    client_id_to_player : Table(u32, Server_Coop_Player);
}

init :: (using coop : *Coop) {

    register_client_server_structs();

    Network.init();

    address : Network.Address;
    address.host = Network.HOST_ANY;
    address.port = SERVER_PORT;

    success := false;
    host, success = Network.host_create(*address, MAX_CLIENTS, 10, 0, 0);
    if !success {
        log_error("Failed to create server");
        return;
    } 


    init(*looping_program);
}

deinit :: (using coop : *Coop) {
    Network.host_destroy(host);
    Network.deinit();
}

// this is a "room", the port is how we differentiate between rooms I guess for now.


// this runs because someone pressed start game with the given game setup.
run_coop_game_mode :: (coop_game_settings : Coop_Game_Settings = .{}) {

    Random.random_seed(cast(u64) current_time_monotonic().low);

    coop : Coop;
    init(*coop);
    defer deinit(*coop);
    using coop;


    while !looping_program.end_program {
        mark_frame_start(*looping_program);
        
        event: Network.Event;
        while Network.host_service(host, *event, 0) == Network.Result_Status.SUCCESS {
            if event.type == {
                case .CONNECT;
                    // players wouldn't be connecting when the thing is running, instead they all connect before the game starts no? but the game has already started? Ok so what if we connect to both at once, and we make sure all players are connected to this server before we start so there is some overlap between the rooms if that makes sense, when does the seettings come across? They'd have to come across in a packet I suppose and by default we have default settings and those updates change it, they can come across as some infrequent thing...
                    
                    log("got a connection");
                    // we need it to be so that you can only connect if you provide a password if that makes sense.
                    // so maybe the top level thing allows you to specify a password and then if so then you can connect or something? not sure yet
                    // will think about later.
                    new_player : Server_Coop_Player;
                    table_add(*client_id_to_player, event.peer.connect_id, new_player);

                    client_id_response := Client_Id_Response.{event.peer.connect_id};
                    packet := packet_create(client_id_response, .RELIABLE);
                    Network.peer_queue_packet(event.peer, 0, packet);
                    log("just sent client id response: %", client_id_response);

                case .DISCONNECT;
                    log("client with id: % disconnected regularly", event.peer.connect_id);
                    table_remove(*client_id_to_player, event.peer.connect_id);

                case .DISCONNECT_TIMEOUT;
                    log("client with id: % disconnected by timeout", event.peer.connect_id);
                    table_remove(*client_id_to_player, event.peer.connect_id);

                case .RECEIVE;
                    packet_data := cast(*void) event.packet.data;


                    // we can do this because we use the serialize module which defines the protocol.
                    type_of_packet : Type = get_type_out(packet_data);
                    
                    // log("got a packet of type: %", type_of_packet);

                    if type_of_packet == Coop_Client_Update {
                        client_update := deserialize_with_type_first(packet_data, Coop_Client_Update);

                        player := table_find_pointer(*client_id_to_player, event.peer.connect_id);
                        if player != null {
                            // synchronize
                            player.mouse_grid_space_x = client_update.mouse_grid_space_x;
                            player.mouse_grid_space_y = client_update.mouse_grid_space_y;

                            set(*player.open_tbs, client_update.open_cell_pressed);
                            set(*player.flag_tbs, client_update.flag_cell_pressed);

                            if game_state == .LIVE {
                                if just_switched_on(player.open_tbs) {
                                    result := handle_board_action(*board, player.mouse_grid_space_x, player.mouse_grid_space_y, .OPEN, player.multi_open, player.multi_flag);

                                    if result == .WIN {
                                        game_state = .WON;
                                        game_state_timer.duration_sec = 3;
                                        start(*game_state_timer);
                                        unready_all_players(*coop);
                                    }

                                    if result == .HIT_MINE {
                                        game_state = .LOST;
                                        game_state_timer.duration_sec = 3;
                                        start(*game_state_timer);
                                        unready_all_players(*coop);
                                    }
                                }

                                if just_switched_on(player.flag_tbs)
                                    handle_board_action(*board, player.mouse_grid_space_x, player.mouse_grid_space_y, .FLAG, player.multi_open, player.multi_flag);
                            }

                            // and then simulate, don't need to above is that I believe.
                            // process_client_input(client_update);

                        }
                        // client_id_to_playerevent.peer.connect_id;
                    }

                    if type_of_packet == Infrequent_Coop_Client_Update { 

                        // if the type holds dynamic memory then this is a memory leak. use temp allocator for this.
                        // also note that if we free this then we can no longer slice the username we have to copy because that memory would get invalidated.
                        infrequent_client_update := deserialize_with_type_first(packet_data, Infrequent_Coop_Client_Update);

                        // log("just got icu: %", infrequent_client_update);

                        player := table_find_pointer(*client_id_to_player, event.peer.connect_id);
                        if player != null {
                            for infrequent_client_update.messages {
                                if it == "/ready" {
                                    player.ready = true;
                                    continue;
                                }
                                if it == "/unready" {
                                    player.ready = false;
                                    continue;
                                }
                                if begins_with(it, "/username ") {
                                    player.username = slice(it, 10, it.count - 10);
                                    continue;
                                }
                                if begins_with(it, "/multi_open ") {
                                    value := slice(it, 12, it.count - 12);
                                    player.multi_open = value == "true";
                                    continue;
                                }
                                if begins_with(it, "/multi_flag ") {
                                    value := slice(it, 12, it.count - 12);
                                    player.multi_flag = value == "true";
                                    continue;
                                }
                                array_add(*messages_to_send_out, it);
                            }
                        }
                    }

                    Network.packet_destroy(event.packet);
            }
        }

        players_ready := 0;
        for client_id_to_player { if it.ready then players_ready += 1; }

        // if you're doing multiplayer it always makes sense to start a game with at least 2 players.
        // if players_ready >= 2 && players_ready == client_id_to_player.count {
        if players_ready >= 2 && players_ready == client_id_to_player.count && game_state == .READY_UP { // for testing purposes
            game_state = .PRE_GAME;

            // generate the board.
            total := coop_game_settings.board_width * coop_game_settings.board_height;
            mines := cast(s32)(cast(float32) total * coop_game_settings.mine_percentage / 100.0 + 0.5);
            if mines < 1  mines = 1;
            if mines >= total  mines = total - 1;

            init(*board, coop_game_settings.board_width, coop_game_settings.board_height, mines);

            if coop_game_settings.no_guess_solvable {
                impossible := generate_no_guess_solvable_board(*board);
                if impossible randomly_place_mines_on_board(*board);
            } else {
                randomly_place_mines_on_board(*board);
            }

            pb := Pregenerated_Board.{board.width, board.height, board.safe_start_row, board.safe_start_col, board.cells};

            // uses the memory of the board, which is fine because we're not going to modify it.
            packet := packet_create(pb, .RELIABLE);
            Network.host_broadcast(host, 0, packet);

            log("just sent out pregenerated board: %", pb);

            game_state_timer.duration_sec = 3;
            start(*game_state_timer);
        }

        if game_state == {
            case .READY_UP;
            case .PRE_GAME;
                if time_up(*game_state_timer) game_state = .LIVE;
            case .LIVE;
            case .WON;
                if time_up(*game_state_timer) game_state = .READY_UP;
            case .LOST;
                if time_up(*game_state_timer) game_state = .READY_UP;
        }

        packet := packet_create(sample_game_update(*coop), .UNRELIABLE_FRAGMENT);
        Network.host_broadcast(host, 0, packet);

        // not sure if this should be in the if
        if ready(*infrequent_send_signal) {
            icgu := sample_infrequent_game_update(*coop);
            packet := packet_create(icgu, .RELIABLE);
            Network.host_broadcast(host, 0, packet);
            // log("just sent out icgu: %", icgu);
        }

        sleep_to_maintain_max_fps(*looping_program);
        mark_frame_end(*looping_program);
    }
}

unready_all_players :: (using coop : *Coop) {
    for * client_id_to_player {
        it.ready = false;
    }
}

sample_game_update :: (using coop : *Coop) -> Coop_Game_Update {
    push_allocator(temp);
    coop_game_update : Coop_Game_Update;

    // array_resize(*coop_game_update.cell_states, coop.board.cells.count);

    for coop.board.cells {
        array_add(*coop_game_update.cell_states, it.state);
    }

    for client_id_to_player {
        table_add(*coop_game_update.client_id_to_player, it_index, it.coop_player);
    }
    return coop_game_update;
}

sample_infrequent_game_update :: (using coop : *Coop) -> Infrequent_Coop_Game_Update {
    infrequent_coop_game_state : Infrequent_Coop_Game_Update;
    infrequent_coop_game_state.game_state = game_state;

    for client_id_to_player {
        table_add(*infrequent_coop_game_state.client_id_to_player , it_index, it.infrequent_coop_player);
    }

    return infrequent_coop_game_state;
}


process_client_input :: (coop_client_update : Coop_Client_Update) { }

process_infrequent_client_input :: (infrequent_coop_client_update : Infrequent_Coop_Client_Update) {

}



