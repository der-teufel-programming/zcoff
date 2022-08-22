const Zcoff = @This();

const std = @import("std");
const assert = std.debug.assert;
const coff = @import("coff.zig");
const fs = std.fs;
const mem = std.mem;

const Allocator = mem.Allocator;

gpa: Allocator,
data: ?[]const u8 = null,
is_image: bool = false,
coff_header_offset: usize = 0,

const pe_offset: usize = 0x3c;
const pe_magic: []const u8 = "PE\x00\x00";

pub fn init(gpa: Allocator) Zcoff {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Zcoff) void {
    if (self.data) |data| {
        self.gpa.free(data);
    }
    self.data = null;
}

pub fn parse(self: *Zcoff, file: fs.File) !void {
    const stat = try file.stat();
    self.data = try file.readToEndAlloc(self.gpa, stat.size);

    var stream = std.io.fixedBufferStream(self.data.?);
    const reader = stream.reader();
    try stream.seekTo(pe_offset);
    const coff_header_offset = try reader.readByte();
    try stream.seekTo(coff_header_offset);
    var buf: [4]u8 = undefined;
    try reader.readNoEof(&buf);
    self.is_image = mem.eql(u8, pe_magic, &buf);

    // Do some basic validation upfront
    if (self.is_image) {
        self.coff_header_offset = coff_header_offset + 4;
        const coff_header = self.getHeader();
        if (coff_header.size_of_optional_header == 0) {
            std.log.err("Required PE header missing for image file", .{});
            return error.MalformedImageFile;
        }
    }
}

pub fn printHeaders(self: *Zcoff, writer: anytype) !void {
    const coff_header = self.getHeader();
    if (self.is_image) {
        try writer.writeAll("PE signature found\n\n");
        try writer.writeAll("File type: EXECUTABLE IMAGE\n\n");
    } else {
        try writer.writeAll("No PE signature found\n\n");
        try writer.writeAll("File type: COFF OBJECT\n\n");
    }

    // COFF header (object and image)
    try writer.writeAll("FILE HEADER VALUES\n");

    {
        try writer.print("{x: >20} machine ({s})\n", .{
            coff_header.machine,
            @tagName(@intToEnum(coff.MachineType, coff_header.machine)),
        });

        const fields = std.meta.fields(coff.CoffHeader);
        inline for (&[_][]const u8{
            "number of sections",
            "time date stamp",
            "file pointer to symbol table",
            "number of symbols",
            "size of optional header",
            "characteristics",
        }) |desc, i| {
            const field = fields[i + 1];
            try writer.print("{x: >20} {s}\n", .{ @field(coff_header, field.name), desc });
        }
    }

    inline for (&[_]struct { flag: u16, desc: []const u8 }{
        .{ .flag = coff.IMAGE_FILE_RELOCS_STRIPPED, .desc = "Relocs stripped" },
        .{ .flag = coff.IMAGE_FILE_EXECUTABLE_IMAGE, .desc = "Executable" },
        .{ .flag = coff.IMAGE_FILE_LINE_NUMS_STRIPPED, .desc = "COFF line numbers have been removed" },
        .{ .flag = coff.IMAGE_FILE_LOCAL_SYMS_STRIPPED, .desc = "COFF symbol table entries for local symbols have been removed" },
        .{ .flag = coff.IMAGE_FILE_AGGRESSIVE_WS_TRIM, .desc = "Aggressively trim working set" },
        .{ .flag = coff.IMAGE_FILE_LARGE_ADDRESS_AWARE, .desc = "Application can handle > 2-GB addresses" },
        .{ .flag = coff.IMAGE_FILE_RESERVED, .desc = "Reserved" },
        .{ .flag = coff.IMAGE_FILE_BYTES_REVERSED_LO, .desc = "Little endian" },
        .{ .flag = coff.IMAGE_FILE_32BIT_MACHINE, .desc = "32-bit" },
        .{ .flag = coff.IMAGE_FILE_DEBUG_STRIPPED, .desc = "Debugging information removed" },
        .{ .flag = coff.IMAGE_FILE_REMOVABLE_RUN_FROM_SWAP, .desc = "Fully load and copy to swap file from removable media" },
        .{ .flag = coff.IMAGE_FILE_NET_RUN_FROM_SWAP, .desc = "Fully load and copy to swap file from network media" },
        .{ .flag = coff.IMAGE_FILE_SYSTEM, .desc = "System file" },
        .{ .flag = coff.IMAGE_FILE_DLL, .desc = "DLL" },
        .{ .flag = coff.IMAGE_FILE_UP_SYSTEM_ONLY, .desc = "Uniprocessor machine only" },
        .{ .flag = coff.IMAGE_FILE_BYTES_REVERSED_HI, .desc = "Big endian" },
    }) |next| {
        if (coff_header.characteristics & next.flag != 0) {
            try writer.print("{s: >22} {s}\n", .{ "", next.desc });
        }
    }
    try writer.writeByte('\n');

    if (coff_header.size_of_optional_header > 0) {
        var stream = std.io.fixedBufferStream(self.data.?);
        const reader = stream.reader();

        const offset = self.coff_header_offset + @sizeOf(coff.CoffHeader);
        try stream.seekTo(offset);

        try writer.writeAll("OPTIONAL HEADER VALUES\n");
        const magic = try reader.readIntLittle(u16);
        try stream.seekBy(-2);

        var counting_stream = std.io.countingReader(reader);
        const creader = counting_stream.reader();

        var number_of_directories: u32 = 0;

        switch (magic) {
            coff.IMAGE_NT_OPTIONAL_HDR32_MAGIC => {
                const pe_header = try creader.readStruct(coff.OptionalHeaderPE32);
                const fields = std.meta.fields(coff.OptionalHeaderPE32);
                inline for (&[_][]const u8{
                    "magic",
                    "linker version (major)",
                    "linker version (minor)",
                    "size of code",
                    "size of initialized data",
                    "size of uninitialized data",
                    "entry point",
                    "base of code",
                    "base of data",
                    "image base",
                    "section alignment",
                    "file alignment",
                    "OS version (major)",
                    "OS version (minor)",
                    "image version (major)",
                    "image version (minor)",
                    "subsystem version (major)",
                    "subsystem version (minor)",
                    "Win32 version",
                    "size of image",
                    "size of headers",
                    "checksum",
                    "subsystem",
                    "DLL characteristics",
                    "size of stack reserve",
                    "size of stack commit",
                    "size of heap reserve",
                    "size of heap commit",
                    "loader flags",
                    "number of RVA and sizes",
                }) |desc, i| {
                    const field = fields[i];
                    try writer.print("{x: >20} {s}", .{ @field(pe_header, field.name), desc });
                    if (mem.eql(u8, field.name, "magic")) {
                        try writer.writeAll(" # (PE32)");
                        try writer.writeByte('\n');
                    } else if (mem.eql(u8, field.name, "dll_characteristics")) {
                        try writer.writeByte('\n');
                        try printDllCharacteristics(pe_header.dll_characteristics, writer);
                    } else if (mem.eql(u8, field.name, "subsystem")) {
                        try writer.print(" # ({s})", .{@tagName(@intToEnum(coff.Subsystem, pe_header.subsystem))});
                        try writer.writeByte('\n');
                    } else try writer.writeByte('\n');
                }
                number_of_directories = pe_header.number_of_rva_and_sizes;
            },
            coff.IMAGE_NT_OPTIONAL_HDR64_MAGIC => {
                const pe_header = try creader.readStruct(coff.OptionalHeaderPE64);
                const fields = std.meta.fields(coff.OptionalHeaderPE64);
                inline for (&[_][]const u8{
                    "magic",
                    "linker version (major)",
                    "linker version (minor)",
                    "size of code",
                    "size of initialized data",
                    "size of uninitialized data",
                    "entry point",
                    "base of code",
                    "image base",
                    "section alignment",
                    "file alignment",
                    "OS version (major)",
                    "OS version (minor)",
                    "image version (major)",
                    "image version (minor)",
                    "subsystem version (major)",
                    "subsystem version (minor)",
                    "Win32 version",
                    "size of image",
                    "size of headers",
                    "checksum",
                    "subsystem",
                    "DLL characteristics",
                    "size of stack reserve",
                    "size of stack commit",
                    "size of heap reserve",
                    "size of heap commit",
                    "loader flags",
                    "number of directories",
                }) |desc, i| {
                    const field = fields[i];
                    try writer.print("{x: >20} {s}", .{ @field(pe_header, field.name), desc });
                    if (mem.eql(u8, field.name, "magic")) {
                        try writer.writeAll(" # (PE32+)");
                        try writer.writeByte('\n');
                    } else if (mem.eql(u8, field.name, "dll_characteristics")) {
                        try writer.writeByte('\n');
                        try printDllCharacteristics(pe_header.dll_characteristics, writer);
                    } else if (mem.eql(u8, field.name, "subsystem")) {
                        try writer.print(" # ({s})", .{@tagName(@intToEnum(coff.Subsystem, pe_header.subsystem))});
                        try writer.writeByte('\n');
                    } else try writer.writeByte('\n');
                }
                number_of_directories = pe_header.number_of_rva_and_sizes;
            },
            else => {
                std.log.err("unknown PE optional header magic: {x}", .{magic});
                return error.UnknownPEOptionalHeaderMagic;
            },
        }

        if (number_of_directories > 0) {
            inline for (&[_][]const u8{
                "Export Directory",
                "Import Directory",
                "Resource Directory",
                "Exception Directory",
                "Certificates Directory",
                "Base Relocation Directory",
                "Debug Directory",
                "Architecture Directory",
                "Global Pointer Directory",
                "Thread Storage Directory",
                "Load Configuration Directory",
                "Bound Import Directory",
                "Import Address Table Directory",
                "Delay Import Directory",
                "COM Descriptor Directory",
                "Reserved Directory",
            }) |desc, i| {
                if (i < number_of_directories) {
                    const data_dir = try creader.readStruct(coff.ImageDataDirectory);
                    try writer.print("{x: >20} [{x: >10}] RVA [size] of {s}\n", .{
                        data_dir.virtual_address,
                        data_dir.size,
                        desc,
                    });
                }
            }
        }

        assert(counting_stream.bytes_read == coff_header.size_of_optional_header);
    }

    // Section table
    if (coff_header.number_of_sections > 0) {
        try writer.writeByte('\n');
        const sections = self.getSectionHeaders();
        const fields = std.meta.fields(coff.SectionHeader);

        for (sections) |*sect_hdr, i| {
            try writer.print("SECTION HEADER #{d}\n", .{i});

            const name = self.getSectionName(sect_hdr);
            try writer.print("{s: >20} name\n", .{name});

            inline for (&[_][]const u8{
                "virtual size",
                "virtual address",
                "size of raw data",
                "file pointer to raw data",
                "file pointer to relocation table",
                "file pointer to line numbers",
                "number of relocations",
                "number of line numbers",
                "flags",
            }) |desc, field_i| {
                const field = fields[field_i + 1];
                try writer.print("{x: >20} {s}\n", .{ @field(sect_hdr, field.name), desc });
                if (mem.eql(u8, field.name, "flags")) {
                    try printSectionFlags(sect_hdr.flags, writer);
                    if (sect_hdr.getAlignment()) |alignment| {
                        try writer.print("{s: >22} {d} byte align\n", .{ "", alignment });
                    }
                }
            }

            try writer.writeByte('\n');
        }
    }
}

fn printSectionFlags(bitset: u32, writer: anytype) !void {
    inline for (&[_]struct { flag: u32, desc: []const u8 }{
        .{ .flag = coff.IMAGE_SCN_TYPE_NO_PAD, .desc = "No padding" },
        .{ .flag = coff.IMAGE_SCN_CNT_CODE, .desc = "Code" },
        .{ .flag = coff.IMAGE_SCN_CNT_INITIALIZED_DATA, .desc = "Initialized data" },
        .{ .flag = coff.IMAGE_SCN_CNT_UNINITIALIZED_DATA, .desc = "Uninitialized data" },
        .{ .flag = coff.IMAGE_SCN_LNK_INFO, .desc = "Comments" },
        .{ .flag = coff.IMAGE_SCN_LNK_REMOVE, .desc = "Discard" },
        .{ .flag = coff.IMAGE_SCN_LNK_COMDAT, .desc = "COMDAT" },
        .{ .flag = coff.IMAGE_SCN_GPREL, .desc = "GP referenced" },
        .{ .flag = coff.IMAGE_SCN_LNK_NRELOC_OVFL, .desc = "Extended relocations" },
        .{ .flag = coff.IMAGE_SCN_MEM_DISCARDABLE, .desc = "Discardable" },
        .{ .flag = coff.IMAGE_SCN_MEM_NOT_CACHED, .desc = "Not cached" },
        .{ .flag = coff.IMAGE_SCN_MEM_NOT_PAGED, .desc = "Not paged" },
        .{ .flag = coff.IMAGE_SCN_MEM_SHARED, .desc = "Shared" },
        .{ .flag = coff.IMAGE_SCN_MEM_EXECUTE, .desc = "Execute" },
        .{ .flag = coff.IMAGE_SCN_MEM_READ, .desc = "Read" },
        .{ .flag = coff.IMAGE_SCN_MEM_WRITE, .desc = "Write" },
    }) |next| {
        if (bitset & next.flag != 0) {
            try writer.print("{s: >22} {s}\n", .{ "", next.desc });
        }
    }
}

fn printDllCharacteristics(bitset: u16, writer: anytype) !void {
    inline for (&[_]struct { flag: u16, desc: []const u8 }{
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA, .desc = "High Entropy Virtual Address" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE, .desc = "Dynamic base" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_FORCE_INTEGRITY, .desc = "Force integrity" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_NX_COMPAT, .desc = "NX compatible" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_NO_ISOLATION, .desc = "No isolation" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_NO_SEH, .desc = "No structured exception handling" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_NO_BIND, .desc = "No bind" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_APPCONTAINER, .desc = "AppContainer" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_WDM_DRIVER, .desc = "WDM Driver" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_GUARD_CF, .desc = "Control Flow Guard" },
        .{ .flag = coff.IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE, .desc = "Terminal Server Aware" },
    }) |next| {
        if (bitset & next.flag != 0) {
            try writer.print("{s: >22} {s}\n", .{ "", next.desc });
        }
    }
}

pub fn printSymbols(self: *Zcoff, writer: anytype) !void {
    const symtab = self.getSymtab() orelse {
        return writer.writeAll("No symbol table found.\n");
    };

    try writer.writeAll("COFF SYMBOL TABLE\n");

    const sections = self.getSectionHeaders();
    const strtab = self.getStrtab().?;
    var slice = symtab.slice(0, null);

    var index: usize = 0;
    var aux_counter: usize = 0;
    var aux_tag: ?Symtab.Tag = null;
    while (slice.next()) |sym| {
        if (aux_counter == 0) {
            try writer.print("{d:0>3} {d:0>8} ", .{ index, sym.value });
            switch (sym.section_number) {
                .UNDEFINED,
                .ABSOLUTE,
                .DEBUG,
                => try writer.print("{s: <9} ", .{@tagName(sym.section_number)}),
                else => try writer.print("SECT{d: <5} ", .{@enumToInt(sym.section_number)}),
            }
            const name = sym.getName() orelse blk: {
                const offset = sym.getNameOffset() orelse return error.MalformedSymbolRecord;
                break :blk strtab.get(offset);
            };
            try writer.print("{s: <6} {s: <8} {s: <20} | {s}\n", .{
                @tagName(sym.@"type".base_type),
                @tagName(sym.@"type".complex_type),
                @tagName(sym.storage_class),
                name,
            });

            aux_tag = aux_tag: {
                switch (sym.section_number) {
                    .UNDEFINED => {
                        if (sym.storage_class == .WEAK_EXTERNAL and sym.value == 0) {
                            break :aux_tag .weak_ext;
                        }
                    },
                    .ABSOLUTE => {},
                    .DEBUG => {
                        if (sym.storage_class == .FILE) {
                            break :aux_tag .file_def;
                        }
                    },
                    else => {
                        if (sym.storage_class == .EXTERNAL and sym.@"type".complex_type == .FUNCTION) {
                            break :aux_tag .func_def;
                        }
                        if (sym.storage_class == .STATIC) {
                            for (sections) |*sect| {
                                const sect_name = self.getSectionName(sect);
                                if (mem.eql(u8, sect_name, name)) {
                                    break :aux_tag .sect_def;
                                }
                            }
                        }
                    },
                }
                break :aux_tag null;
            };

            aux_counter = sym.number_of_aux_symbols;
        } else {
            if (aux_tag) |tag| switch (symtab.at(index, tag)) {
                .weak_ext => |weak_ext| {
                    try writer.print("     Default index {x: >8} {s}\n", .{ weak_ext.tag_index, @tagName(weak_ext.flag) });
                },
                .file_def => |*file_def| {
                    try writer.print("     {s}\n", .{file_def.getFileName()});
                },
                .sect_def => |sect_def| {
                    // TODO COMDAT section
                    try writer.print("     Section length {x: >4}, #relocs {x: >4}, #linenums {x: >4}, checksum {x: >8}\n", .{
                        sect_def.length,
                        sect_def.number_of_relocations,
                        sect_def.number_of_linenumbers,
                        sect_def.checksum,
                    });
                },
                else => {},
            };

            aux_counter -= 1;
        }

        index += 1;
    }

    try writer.print("\nString table size = 0x{x} bytes\n", .{strtab.buffer.len});
}

fn getHeader(self: *Zcoff) coff.CoffHeader {
    return @ptrCast(*align(1) coff.CoffHeader, self.data.?[self.coff_header_offset..][0..@sizeOf(coff.CoffHeader)]).*;
}

const Symtab = struct {
    buffer: []const u8,

    fn len(self: Symtab) usize {
        return @divExact(self.buffer.len, coff.Symbol.sizeOf());
    }

    const Tag = enum {
        symbol,
        func_def,
        // func_def_di,
        weak_ext,
        file_def,
        sect_def,
    };

    const Record = union(Tag) {
        symbol: coff.Symbol,
        func_def: coff.FunctionDefinition,
        weak_ext: coff.WeakExternalDefinition,
        file_def: coff.FileDefinition,
        sect_def: coff.SectionDefinition,
    };

    /// Lives as long as Symtab instance.
    fn at(self: Symtab, index: usize, tag: Tag) Record {
        const offset = index * coff.Symbol.sizeOf();
        const raw = self.buffer[offset..][0..coff.Symbol.sizeOf()];
        return switch (tag) {
            .symbol => .{ .symbol = asSymbol(raw) },
            .func_def => .{ .func_def = asFuncDef(raw) },
            .weak_ext => .{ .weak_ext = asWeakExtDef(raw) },
            .file_def => .{ .file_def = asFileDef(raw) },
            .sect_def => .{ .sect_def = asSectDef(raw) },
        };
    }

    fn asSymbol(raw: []const u8) coff.Symbol {
        return .{
            .name = raw[0..8].*,
            .value = mem.readIntLittle(u32, raw[8..12]),
            .section_number = @intToEnum(coff.SectionNumber, mem.readIntLittle(u16, raw[12..14])),
            .@"type" = @bitCast(coff.SymType, mem.readIntLittle(u16, raw[14..16])),
            .storage_class = @intToEnum(coff.StorageClass, raw[16]),
            .number_of_aux_symbols = raw[17],
        };
    }

    fn asFuncDef(raw: []const u8) coff.FunctionDefinition {
        return .{
            .tag_index = mem.readIntLittle(u32, raw[0..4]),
            .total_size = mem.readIntLittle(u32, raw[4..8]),
            .pointer_to_linenumber = mem.readIntLittle(u32, raw[8..12]),
            .pointer_to_next_function = mem.readIntLittle(u32, raw[12..16]),
            .unused = raw[16..18].*,
        };
    }

    fn asWeakExtDef(raw: []const u8) coff.WeakExternalDefinition {
        return .{
            .tag_index = mem.readIntLittle(u32, raw[0..4]),
            .flag = @intToEnum(coff.WeakExternalFlag, mem.readIntLittle(u32, raw[4..8])),
            .unused = raw[8..18].*,
        };
    }

    fn asFileDef(raw: []const u8) coff.FileDefinition {
        return .{
            .file_name = raw[0..18].*,
        };
    }

    fn asSectDef(raw: []const u8) coff.SectionDefinition {
        return .{
            .length = mem.readIntLittle(u32, raw[0..4]),
            .number_of_relocations = mem.readIntLittle(u16, raw[4..6]),
            .number_of_linenumbers = mem.readIntLittle(u16, raw[6..8]),
            .checksum = mem.readIntLittle(u32, raw[8..12]),
            .number = mem.readIntLittle(u16, raw[12..14]),
            .selection = raw[14],
            .unused = raw[15..18].*,
        };
    }

    const Slice = struct {
        buffer: []const u8,
        num: usize,
        count: usize = 0,

        /// Lives as long as Symtab instance.
        fn next(self: *Slice) ?coff.Symbol {
            if (self.count >= self.num) return null;
            const sym = asSymbol(self.buffer[0..coff.Symbol.sizeOf()]);
            self.count += 1;
            self.buffer = self.buffer[coff.Symbol.sizeOf()..];
            return sym;
        }
    };

    fn slice(self: Symtab, start: usize, end: ?usize) Slice {
        const offset = start * coff.Symbol.sizeOf();
        const llen = if (end) |e| e * coff.Symbol.sizeOf() else self.buffer.len;
        const num = @divExact(llen - offset, coff.Symbol.sizeOf());
        return Slice{ .buffer = self.buffer[offset..][0..llen], .num = num };
    }
};

fn getSymtab(self: *Zcoff) ?Symtab {
    const coff_header = self.getHeader();
    if (coff_header.pointer_to_symbol_table == 0) return null;

    const offset = coff_header.pointer_to_symbol_table;
    const size = coff_header.number_of_symbols * coff.Symbol.sizeOf();
    return .{ .buffer = self.data.?[offset..][0..size] };
}

const Strtab = struct {
    buffer: []const u8,

    fn get(self: Strtab, off: u32) []const u8 {
        assert(off < self.buffer.len);
        return mem.sliceTo(@ptrCast([*:0]const u8, self.buffer.ptr + off), 0);
    }
};

fn getStrtab(self: *Zcoff) ?Strtab {
    const coff_header = self.getHeader();
    if (coff_header.pointer_to_symbol_table == 0) return null;

    const offset = coff_header.pointer_to_symbol_table + coff.Symbol.sizeOf() * coff_header.number_of_symbols;
    const size = mem.readIntLittle(u32, self.data.?[offset..][0..4]);
    return .{ .buffer = self.data.?[offset..][0..size] };
}

fn getSectionHeaders(self: *Zcoff) []align(1) const coff.SectionHeader {
    const coff_header = self.getHeader();
    const offset = self.coff_header_offset + @sizeOf(coff.CoffHeader) + coff_header.size_of_optional_header;
    return @ptrCast([*]align(1) coff.SectionHeader, self.data.?.ptr + offset)[0..coff_header.number_of_sections];
}

fn getSectionName(self: *Zcoff, sect_hdr: *align(1) const coff.SectionHeader) []const u8 {
    const name = sect_hdr.getName() orelse blk: {
        const strtab = self.getStrtab().?;
        const name_offset = sect_hdr.getNameOffset().?;
        break :blk strtab.get(name_offset);
    };
    return name;
}
