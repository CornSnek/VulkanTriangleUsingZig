const std=@import("std");
const LazyPath=std.Build.LazyPath;
const InstallDir=std.Build.InstallDir;
const ShaderFilesDir="shader_files";
const InstallSpirVDir="spirv";
const SpirVFilesDir=ShaderFilesDir++"/"++InstallSpirVDir;
const GLSLVPath="glslangValidator";
pub fn build(b: *std.Build) !void {
    _ = b.findProgram(&.{GLSLVPath},&.{}) catch return error.GLSLangValidatorNotInstalled;
    var css=CompileShadersStep.init(b);
    const embed_shaders=b.addInstallDirectory(.{
        .source_dir=LazyPath.relative(SpirVFilesDir),
        .install_dir=InstallDir{.custom="../src"}, //Places the SPIR-V files in src/spirv to embed in the executable.
        .install_subdir=InstallSpirVDir,
    });
    const target=b.standardTargetOptions(.{});
    const optimize=b.standardOptimizeOption(.{});
    const exe=b.addExecutable(.{
        .name="SDL_Vulkan",
        .root_source_file=LazyPath.relative("src/main.zig"),
        .link_libc=true,
        .target=target,
        .optimize=optimize,
    });
    b.installArtifact(exe);
    const run_cmd=b.addRunArtifact(exe);
    const run_step=b.step("run", "Run the app");
    const compile_step=b.step("compile", "Validate and compile the shaders");
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("vulkan");
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    compile_step.dependOn(&embed_shaders.step);
    exe.step.dependOn(&embed_shaders.step); //Place the shaders in src/spirv before building the executable.
    embed_shaders.step.dependOn(&css.step);
}
const CompileShadersStep=struct{
    step: std.build.Step,
    b: *std.Build,
    pub fn init(b:*std.Build) *@This(){
        const self=b.allocator.create(@This()) catch @panic("OOM");
        self.*=.{
            .step=std.build.Step.init(.{
                .id=.custom,
                .name="Compile Shaders Step",
                .owner=b,
                .makeFn=make_fn,
            }),
            .b=b,
        };
        return self;
    }
    const ShaderFileSlices=struct{
        abs_file:[]const u8,
        output_spir:[]const u8,
    };
    /// Allocations from std.Build seem to be an arena (No need to deallocate)
    fn make_fn(step:*std.build.Step,progress:*std.Progress.Node) anyerror!void {
        var Node=progress.start("Compile Shaders Step",1);
        var self=@fieldParentPtr(@This(),"step",step);
        const arena=self.b.allocator;
        var code:u8=undefined;
        _ = self.b.execAllowFail(&.{"mkdir","-p",SpirVFilesDir++"/"},&code,.Ignore) catch @panic("OOM");
        var result=self.b.execAllowFail(&.{"find",ShaderFilesDir,"-type","f","-not","-name","*.spv"},&code,.Ignore) catch @panic("OOM");
        //0:=absolute path file, 1:=only the file name, 2:=output to spirv as .spv file
        var shader_files=arena.alloc(ShaderFileSlices,0) catch @panic("OOM");
        var shader_files_count:usize=0;
        var shaders_it=std.mem.tokenizeSequence(u8,result,"\n");
        while(shaders_it.next()) |abs_file| {
            shader_files=arena.realloc(shader_files,shader_files_count+1) catch @panic("OOM");
            const file_only=abs_file[ShaderFilesDir.len+1..abs_file.len]; //Exclude ShaderFiles string including +1 for '/'.
            shader_files[shader_files_count].abs_file=abs_file;
            shader_files[shader_files_count].output_spir=std.mem.join(arena,"",&.{SpirVFilesDir++"/",file_only,".spv"}) catch @panic("OOM");
            shader_files_count+=1;
        }
        for(shader_files) |file| {
            std.debug.print("Compiling '{s}' to '{s}' with --target-env vulkan1.2\n",.{file.abs_file,file.output_spir});
            var validator_result=try std.ChildProcess.exec(.{
                .allocator=arena,
                .argv=&.{GLSLVPath,file.abs_file,"-o",file.output_spir,"--target-env","vulkan1.2"},
            });
            switch(validator_result.term){
                .Exited => |exit_code| {
                    std.debug.print("Exit Code: {}, stdout:\n{s}\n",.{exit_code,validator_result.stdout});
                    if(exit_code!=0) return error.SPVCompilationFailure;
                },
                else=>return error.UnexpectedTermination,
            }
        }
        Node.end();
        progress.end();
    }
};