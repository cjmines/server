OUTPUT_EXECUTABLE_NAME :: "cj_mines_server";

#run {
    set_build_options_dc(.{do_output = false});

    args := get_build_options().compile_time_command_line;
    target_arm := array_find(args, "-arm64");

    cpu_target := CPU;
    if array_find(args, "-x64")  cpu_target = .X64;
    if target_arm                cpu_target = .ARM64;

    make_directory_if_it_does_not_exist("bin", recursive = true);

    w := compiler_create_workspace("Target workspace");
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.cpu_target = cpu_target;
    options.output_executable_name = OUTPUT_EXECUTABLE_NAME;
    options.output_path = "bin/";
    if target_arm {
        options.backend = .LLVM;
        options.llvm_options.target_system_features = "+lse";
    }

    import_path: [..] string;
    array_add(*import_path, ..options.import_path);
    array_add(*import_path, "src/");
    options.import_path = import_path;

    set_build_options(options, w);

    compiler_begin_intercept(w);
    add_build_file("src/main.jai", w);
    while true {
        message := compiler_wait_for_message();
        if message.kind == .ERROR   exit(1);
        if message.kind == .COMPLETE break;
    }
    compiler_end_intercept(w);
};

#import "Basic";
#import "Compiler";
#import "File";
#import "String";
