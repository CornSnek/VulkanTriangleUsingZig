const std=@import("std");
pub const VertShader=a: {
    const arr align(@alignOf(u32))=@embedFile("spirv/shader.vert.spv").*;
    break :a &arr;
};
pub const FragShader=a: {
    const arr align(@alignOf(u32))=@embedFile("spirv/shader.frag.spv").*;
    break :a &arr;
};