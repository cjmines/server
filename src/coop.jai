Network :: #import "tbx/network";
#import "tbx/engine";
#import "tbx/time";
#import "tbx/serialize";
#import "tbx/temporal_binary_switch";

#import "tbx/section_logger"()(LOGGING=false);

#import "shared";
#import "game_logic";
#import "directory_packets";

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
}


Coop :: struct {
    board : Board;
    host : *Network.Host;
    looping_program : Looping_Program;
    infrequent_send_signal := Periodic_Signal.{frequency_hz = 2};

    game_state : Coop_Game_State;
    game_state_timer : Timer;

    orchestrator : *Network.Peer;
    connected_to_orchestrator := false;

    messages_to_send_out : [..] string;

    sent_pregenerated_board := false;

    client_id_to_player : Table(u32, Server_Coop_Player);
}

init :: (using coop : *Coop, port: u16) {
    register_client_server_structs();
    register_directory_packet_types();

    Network.init();

    address : Network.Address;
    address.ip = Network.HOST_ANY;
    // address.port = SERVER_PORT;
    address.port = port;

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


// todo this can be moved into the network code eventually.

disconnect_all :: (host: *Network.Host, timeout_sec: float32 = 2.0) {

    // request disconnect from all connected peers
    connected_count: u32 = 0;
    for * host.peers {
        if it.state == .CONNECTED {
            Network.peer_disconnect(it, data = 0);
            connected_count += 1;
        }
    }

    if connected_count == 0 return;

    // service the host until everyone has disconnected or we time out
    timeout_ms := cast(s64)(timeout_sec * 1000.0);
    start_time := current_time_monotonic();

    while connected_count > 0 {
        elapsed_ms := to_milliseconds(current_time_monotonic() - start_time);
        if elapsed_ms >= timeout_ms break;

        event: Network.Event;
        // service with a small wait so we don't spin at 100% cpu
        result := Network.host_service(host, *event, max_time_to_wait_for_events_ms = 100);

        if result > 0 {
            if event.type == {
                case .RECEIVE;
                    // Discard any incoming packets during shutdown
                    Network.packet_destroy(event.packet);

                case .DISCONNECT; #through;
                case .DISCONNECT_TIMEOUT;
                    connected_count -= 1;
            }
        }
    }

    // force-reset any peers that still haven't disconnected
    for * host.peers {
        if it.state != .DISCONNECTED {
            Network.peer_reset(it);
        }
    }
}

generate_board :: (coop_game_settings : Coop_Game_Settings, board : *Board) -> Pregenerated_Board { // the return value is completely stack allocated.

    // generate the board.
    total := coop_game_settings.board_width * coop_game_settings.board_height;
    mines := coop_game_settings.mine_count;
    if mines < 1  mines = 1;
    if mines >= total  mines = total - 1;

    init(board, coop_game_settings.board_width, coop_game_settings.board_height, mines);

    if coop_game_settings.no_guess_solvable {
        able_to_find_one := generate_no_guess_solvable_board(board);
        if !able_to_find_one {
            randomly_place_mines_on_board(board);
        }
    } else {
        randomly_place_mines_on_board(board);
    }

    pb := Pregenerated_Board.{board.width, board.height, board.safe_start_row, board.safe_start_col, board.cells};

    return pb;
}


// this runs because someone pressed start game with the given game setup.
// need to passs the id of the owning lobby.

run_coop_game_mode :: (coop_game_settings : Coop_Game_Settings, id_of_owning_lobby : u32, port : u16) {

    Random.random_seed(cast(u64) current_time_monotonic().low);

    coop : Coop;
    init(*coop, port);
    defer deinit(*coop);
    using coop;

    server_address : string;
    shutting_down := false;

    run_locally := true;

    pregenerated_board := generate_board(coop_game_settings, *board);

    // send_server_metadata_to_orchestrator_signal := Periodic_Signal.{frequency_hz=1}; // could be even slower than this if need be.

    // we no longer need to connect to the directory server, instead we connect to our orchestrator
    // and that orchestrator connects to the directory server.
    // startfold connect to orchestrator

    orchestrator_port :: 7778;
    // this orchestrator is always on the same computer.
    server_address = "127.0.0.1";

    address := Network.get_host_ip_address(server_address);
    address.port = orchestrator_port;

    // it's possible for this to return null.
    orchestrator = Network.host_request_connect(coop.host, *address, 10, 5);

    event: Network.Event;

    // because the only event we'll receive now is a connect or none event, we can just use an if statement instead of the while.

    if Network.host_service(host, *event, 3000) > 0 {
        if event.type == .CONNECT {
            if event.peer == orchestrator {
                log("connected to orchestrator");
                connected_to_orchestrator = true;
                Network.queue_send(orchestrator, 0, packet_create(Server_Started.{id_of_owning_lobby}, .RELIABLE));
            } else {
                log("connected to something, but it wasn't the orchestrator");
            }
        }
    }

    if !connected_to_orchestrator {
        log_error("wasn't able to connect to directory server, not starting the server");
        return;
    }

    // endfold connect to orchestrator



    // for pregame
    game_state_timer.duration_sec = 3;
    start(*game_state_timer);

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

                    Network.queue_send(event.peer, 0, packet_create(Client_Id_Response.{event.peer.connect_id}, .RELIABLE));
                    Network.queue_send(event.peer, 0, packet_create(pregenerated_board, .RELIABLE));
                    // log("just sent client id response: %", client_id_response);

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
                        coop_client_update := deserialize_with_type_first(packet_data, Coop_Client_Update);

                        player := table_find_pointer(*client_id_to_player, event.peer.connect_id);
                        if player != null {
                            // synchronize

                            for client_update : coop_client_update.updates {

                                player.mouse_grid_space_x = client_update.mouse_grid_space_x;
                                player.mouse_grid_space_y = client_update.mouse_grid_space_y;

                                set(*player.open_tbs, client_update.open_cell_pressed);
                                set(*player.flag_tbs, client_update.flag_cell_pressed);

                                player.last_processed_client_input_number = client_update.number;

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
                            }
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

                                if begins_with(it, "/initials ") {
                                    player.initials = slice(it, 10, it.count - 10);
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


        if game_state == {
            case .PRE_GAME;
                if time_up(*game_state_timer) game_state = .LIVE;
            case .LIVE;
            case .WON;
                // if time_up(*game_state_timer) game_state = .READY_UP;
                if time_up(*game_state_timer) looping_program.end_program = true;
            case .LOST;
                // if time_up(*game_state_timer) game_state = .READY_UP;
                if time_up(*game_state_timer) looping_program.end_program = true;
        }

        Network.queue_broadcast(host, 0, packet_create(sample_game_update(*coop), .UNRELIABLE_FRAGMENT));

        // not sure if this should be in the if
        if ready(*infrequent_send_signal) {
            icgu := sample_infrequent_game_update(*coop);
            packet := packet_create(icgu, .RELIABLE);
            Network.queue_broadcast(host, 0, packet);
            // log("just sent out icgu: %", icgu);
        }

        // if ready(*send_server_metadata_to_orchestrator_signal) {
        //     Network.queue_send(orchestrator, 0, packet_create(server_metadata, .RELIABLE));
        // }

        sleep_to_maintain_max_fps(*looping_program);
        mark_frame_end(*looping_program);
    }

    disconnect_all(coop.host);
    log("server just closed");
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



