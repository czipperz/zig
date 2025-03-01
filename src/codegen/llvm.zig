const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Compilation = @import("../Compilation.zig");
const llvm = @import("llvm/bindings.zig");
const link = @import("../link.zig");
const log = std.log.scoped(.codegen);
const math = std.math;

const Module = @import("../Module.zig");
const TypedValue = @import("../TypedValue.zig");
const Zir = @import("../Zir.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");

const Value = @import("../value.zig").Value;
const Type = @import("../type.zig").Type;

const LazySrcLoc = Module.LazySrcLoc;

pub fn targetTriple(allocator: *Allocator, target: std.Target) ![:0]u8 {
    const llvm_arch = switch (target.cpu.arch) {
        .arm => "arm",
        .armeb => "armeb",
        .aarch64 => "aarch64",
        .aarch64_be => "aarch64_be",
        .aarch64_32 => "aarch64_32",
        .arc => "arc",
        .avr => "avr",
        .bpfel => "bpfel",
        .bpfeb => "bpfeb",
        .csky => "csky",
        .hexagon => "hexagon",
        .mips => "mips",
        .mipsel => "mipsel",
        .mips64 => "mips64",
        .mips64el => "mips64el",
        .msp430 => "msp430",
        .powerpc => "powerpc",
        .powerpcle => "powerpcle",
        .powerpc64 => "powerpc64",
        .powerpc64le => "powerpc64le",
        .r600 => "r600",
        .amdgcn => "amdgcn",
        .riscv32 => "riscv32",
        .riscv64 => "riscv64",
        .sparc => "sparc",
        .sparcv9 => "sparcv9",
        .sparcel => "sparcel",
        .s390x => "s390x",
        .tce => "tce",
        .tcele => "tcele",
        .thumb => "thumb",
        .thumbeb => "thumbeb",
        .i386 => "i386",
        .x86_64 => "x86_64",
        .xcore => "xcore",
        .nvptx => "nvptx",
        .nvptx64 => "nvptx64",
        .le32 => "le32",
        .le64 => "le64",
        .amdil => "amdil",
        .amdil64 => "amdil64",
        .hsail => "hsail",
        .hsail64 => "hsail64",
        .spir => "spir",
        .spir64 => "spir64",
        .kalimba => "kalimba",
        .shave => "shave",
        .lanai => "lanai",
        .wasm32 => "wasm32",
        .wasm64 => "wasm64",
        .renderscript32 => "renderscript32",
        .renderscript64 => "renderscript64",
        .ve => "ve",
        .spu_2 => return error.@"LLVM backend does not support SPU Mark II",
        .spirv32 => return error.@"LLVM backend does not support SPIR-V",
        .spirv64 => return error.@"LLVM backend does not support SPIR-V",
    };

    const llvm_os = switch (target.os.tag) {
        .freestanding => "unknown",
        .ananas => "ananas",
        .cloudabi => "cloudabi",
        .dragonfly => "dragonfly",
        .freebsd => "freebsd",
        .fuchsia => "fuchsia",
        .ios => "ios",
        .kfreebsd => "kfreebsd",
        .linux => "linux",
        .lv2 => "lv2",
        .macos => "macosx",
        .netbsd => "netbsd",
        .openbsd => "openbsd",
        .solaris => "solaris",
        .windows => "windows",
        .zos => "zos",
        .haiku => "haiku",
        .minix => "minix",
        .rtems => "rtems",
        .nacl => "nacl",
        .aix => "aix",
        .cuda => "cuda",
        .nvcl => "nvcl",
        .amdhsa => "amdhsa",
        .ps4 => "ps4",
        .elfiamcu => "elfiamcu",
        .tvos => "tvos",
        .watchos => "watchos",
        .mesa3d => "mesa3d",
        .contiki => "contiki",
        .amdpal => "amdpal",
        .hermit => "hermit",
        .hurd => "hurd",
        .wasi => "wasi",
        .emscripten => "emscripten",
        .uefi => "windows",

        .opencl,
        .glsl450,
        .vulkan,
        .plan9,
        .other,
        => "unknown",
    };

    const llvm_abi = switch (target.abi) {
        .none => "unknown",
        .gnu => "gnu",
        .gnuabin32 => "gnuabin32",
        .gnuabi64 => "gnuabi64",
        .gnueabi => "gnueabi",
        .gnueabihf => "gnueabihf",
        .gnux32 => "gnux32",
        .gnuilp32 => "gnuilp32",
        .code16 => "code16",
        .eabi => "eabi",
        .eabihf => "eabihf",
        .android => "android",
        .musl => "musl",
        .musleabi => "musleabi",
        .musleabihf => "musleabihf",
        .msvc => "msvc",
        .itanium => "itanium",
        .cygnus => "cygnus",
        .coreclr => "coreclr",
        .simulator => "simulator",
        .macabi => "macabi",
    };

    return std.fmt.allocPrintZ(allocator, "{s}-unknown-{s}-{s}", .{ llvm_arch, llvm_os, llvm_abi });
}

pub const Object = struct {
    llvm_module: *const llvm.Module,
    context: *const llvm.Context,
    target_machine: *const llvm.TargetMachine,

    pub fn create(gpa: *Allocator, options: link.Options) !*Object {
        const obj = try gpa.create(Object);
        errdefer gpa.destroy(obj);
        obj.* = try Object.init(gpa, options);
        return obj;
    }

    pub fn init(gpa: *Allocator, options: link.Options) !Object {
        const context = llvm.Context.create();
        errdefer context.dispose();

        initializeLLVMTargets();

        const root_nameZ = try gpa.dupeZ(u8, options.root_name);
        defer gpa.free(root_nameZ);
        const llvm_module = llvm.Module.createWithName(root_nameZ.ptr, context);
        errdefer llvm_module.dispose();

        const llvm_target_triple = try targetTriple(gpa, options.target);
        defer gpa.free(llvm_target_triple);

        var error_message: [*:0]const u8 = undefined;
        var target: *const llvm.Target = undefined;
        if (llvm.Target.getFromTriple(llvm_target_triple.ptr, &target, &error_message).toBool()) {
            defer llvm.disposeMessage(error_message);

            log.err("LLVM failed to parse '{s}': {s}", .{ llvm_target_triple, error_message });
            return error.InvalidLlvmTriple;
        }

        const opt_level: llvm.CodeGenOptLevel = if (options.optimize_mode == .Debug)
            .None
        else
            .Aggressive;

        const reloc_mode: llvm.RelocMode = if (options.pic)
            .PIC
        else if (options.link_mode == .Dynamic)
            llvm.RelocMode.DynamicNoPIC
        else
            .Static;

        const code_model: llvm.CodeModel = switch (options.machine_code_model) {
            .default => .Default,
            .tiny => .Tiny,
            .small => .Small,
            .kernel => .Kernel,
            .medium => .Medium,
            .large => .Large,
        };

        // TODO handle float ABI better- it should depend on the ABI portion of std.Target
        const float_abi: llvm.ABIType = .Default;

        // TODO a way to override this as part of std.Target ABI?
        const abi_name: ?[*:0]const u8 = switch (options.target.cpu.arch) {
            .riscv32 => switch (options.target.os.tag) {
                .linux => "ilp32d",
                else => "ilp32",
            },
            .riscv64 => switch (options.target.os.tag) {
                .linux => "lp64d",
                else => "lp64",
            },
            else => null,
        };

        const target_machine = llvm.TargetMachine.create(
            target,
            llvm_target_triple.ptr,
            if (options.target.cpu.model.llvm_name) |s| s.ptr else null,
            options.llvm_cpu_features,
            opt_level,
            reloc_mode,
            code_model,
            options.function_sections,
            float_abi,
            abi_name,
        );
        errdefer target_machine.dispose();

        return Object{
            .llvm_module = llvm_module,
            .context = context,
            .target_machine = target_machine,
        };
    }

    pub fn deinit(self: *Object) void {
        self.target_machine.dispose();
        self.llvm_module.dispose();
        self.context.dispose();
        self.* = undefined;
    }

    pub fn destroy(self: *Object, gpa: *Allocator) void {
        self.deinit();
        gpa.destroy(self);
    }

    fn initializeLLVMTargets() void {
        llvm.initializeAllTargets();
        llvm.initializeAllTargetInfos();
        llvm.initializeAllTargetMCs();
        llvm.initializeAllAsmPrinters();
        llvm.initializeAllAsmParsers();
    }

    fn locPath(
        arena: *Allocator,
        opt_loc: ?Compilation.EmitLoc,
        cache_directory: Compilation.Directory,
    ) !?[*:0]u8 {
        const loc = opt_loc orelse return null;
        const directory = loc.directory orelse cache_directory;
        const slice = try directory.joinZ(arena, &[_][]const u8{loc.basename});
        return slice.ptr;
    }

    pub fn flushModule(self: *Object, comp: *Compilation) !void {
        if (comp.verbose_llvm_ir) {
            self.llvm_module.dump();
        }

        if (std.debug.runtime_safety) {
            var error_message: [*:0]const u8 = undefined;
            // verifyModule always allocs the error_message even if there is no error
            defer llvm.disposeMessage(error_message);

            if (self.llvm_module.verify(.ReturnStatus, &error_message).toBool()) {
                std.debug.print("\n{s}\n", .{error_message});
                @panic("LLVM module verification failed");
            }
        }

        var arena_allocator = std.heap.ArenaAllocator.init(comp.gpa);
        defer arena_allocator.deinit();
        const arena = &arena_allocator.allocator;

        const mod = comp.bin_file.options.module.?;
        const cache_dir = mod.zig_cache_artifact_directory;

        const emit_bin_path: ?[*:0]const u8 = if (comp.bin_file.options.emit != null) blk: {
            const obj_basename = try std.zig.binNameAlloc(arena, .{
                .root_name = comp.bin_file.options.root_name,
                .target = comp.bin_file.options.target,
                .output_mode = .Obj,
            });
            if (cache_dir.joinZ(arena, &[_][]const u8{obj_basename})) |p| {
                break :blk p.ptr;
            } else |err| {
                return err;
            }
        } else null;

        const emit_asm_path = try locPath(arena, comp.emit_asm, cache_dir);
        const emit_llvm_ir_path = try locPath(arena, comp.emit_llvm_ir, cache_dir);
        const emit_llvm_bc_path = try locPath(arena, comp.emit_llvm_bc, cache_dir);

        var error_message: [*:0]const u8 = undefined;
        if (self.target_machine.emitToFile(
            self.llvm_module,
            &error_message,
            comp.bin_file.options.optimize_mode == .Debug,
            comp.bin_file.options.optimize_mode == .ReleaseSmall,
            comp.time_report,
            comp.bin_file.options.tsan,
            comp.bin_file.options.lto,
            emit_asm_path,
            emit_bin_path,
            emit_llvm_ir_path,
            emit_llvm_bc_path,
        )) {
            defer llvm.disposeMessage(error_message);

            const emit_asm_msg = emit_asm_path orelse "(none)";
            const emit_bin_msg = emit_bin_path orelse "(none)";
            const emit_llvm_ir_msg = emit_llvm_ir_path orelse "(none)";
            const emit_llvm_bc_msg = emit_llvm_bc_path orelse "(none)";
            log.err("LLVM failed to emit asm={s} bin={s} ir={s} bc={s}: {s}", .{
                emit_asm_msg,  emit_bin_msg, emit_llvm_ir_msg, emit_llvm_bc_msg,
                error_message,
            });
            return error.FailedToEmit;
        }
    }

    pub fn updateFunc(
        self: *Object,
        module: *Module,
        func: *Module.Fn,
        air: Air,
        liveness: Liveness,
    ) !void {
        const decl = func.owner_decl;

        var dg: DeclGen = .{
            .context = self.context,
            .object = self,
            .module = module,
            .decl = decl,
            .err_msg = null,
            .gpa = module.gpa,
        };

        const llvm_func = try dg.resolveLlvmFunction(decl);

        // This gets the LLVM values from the function and stores them in `dg.args`.
        const fn_param_len = decl.ty.fnParamLen();
        var args = try dg.gpa.alloc(*const llvm.Value, fn_param_len);

        for (args) |*arg, i| {
            arg.* = llvm.getParam(llvm_func, @intCast(c_uint, i));
        }

        // We remove all the basic blocks of a function to support incremental
        // compilation!
        // TODO: remove all basic blocks if functions can have more than one
        if (llvm_func.getFirstBasicBlock()) |bb| {
            bb.deleteBasicBlock();
        }

        const builder = dg.context.createBuilder();

        const entry_block = dg.context.appendBasicBlock(llvm_func, "Entry");
        builder.positionBuilderAtEnd(entry_block);

        var fg: FuncGen = .{
            .gpa = dg.gpa,
            .air = air,
            .liveness = liveness,
            .context = dg.context,
            .dg = &dg,
            .builder = builder,
            .args = args,
            .arg_index = 0,
            .func_inst_table = .{},
            .entry_block = entry_block,
            .latest_alloca_inst = null,
            .llvm_func = llvm_func,
            .blocks = .{},
        };
        defer fg.deinit();

        fg.genBody(air.getMainBody()) catch |err| switch (err) {
            error.CodegenFail => {
                decl.analysis = .codegen_failure;
                try module.failed_decls.put(module.gpa, decl, dg.err_msg.?);
                dg.err_msg = null;
                return;
            },
            else => |e| return e,
        };

        const decl_exports = module.decl_exports.get(decl) orelse &[0]*Module.Export{};
        try self.updateDeclExports(module, decl, decl_exports);
    }

    pub fn updateDecl(self: *Object, module: *Module, decl: *Module.Decl) !void {
        var dg: DeclGen = .{
            .context = self.context,
            .object = self,
            .module = module,
            .decl = decl,
            .err_msg = null,
            .gpa = module.gpa,
        };
        dg.genDecl() catch |err| switch (err) {
            error.CodegenFail => {
                decl.analysis = .codegen_failure;
                try module.failed_decls.put(module.gpa, decl, dg.err_msg.?);
                dg.err_msg = null;
                return;
            },
            else => |e| return e,
        };
    }

    pub fn updateDeclExports(
        self: *Object,
        module: *const Module,
        decl: *const Module.Decl,
        exports: []const *Module.Export,
    ) !void {
        const llvm_fn = self.llvm_module.getNamedFunction(decl.name).?;
        const is_extern = decl.val.tag() == .extern_fn;
        if (is_extern or exports.len != 0) {
            llvm_fn.setLinkage(.External);
            llvm_fn.setUnnamedAddr(.False);
        } else {
            llvm_fn.setLinkage(.Internal);
            llvm_fn.setUnnamedAddr(.True);
        }
        // TODO LLVM C API does not support deleting aliases. We need to
        // patch it to support this or figure out how to wrap the C++ API ourselves.
        // Until then we iterate over existing aliases and make them point
        // to the correct decl, or otherwise add a new alias. Old aliases are leaked.
        for (exports) |exp| {
            const exp_name_z = try module.gpa.dupeZ(u8, exp.options.name);
            defer module.gpa.free(exp_name_z);

            if (self.llvm_module.getNamedGlobalAlias(exp_name_z.ptr, exp_name_z.len)) |alias| {
                alias.setAliasee(llvm_fn);
            } else {
                const alias = self.llvm_module.addAlias(llvm_fn.typeOf(), llvm_fn, exp_name_z);
                _ = alias;
            }
        }
    }
};

pub const DeclGen = struct {
    context: *const llvm.Context,
    object: *Object,
    module: *Module,
    decl: *Module.Decl,
    err_msg: ?*Module.ErrorMsg,

    gpa: *Allocator,

    fn todo(self: *DeclGen, comptime format: []const u8, args: anytype) error{ OutOfMemory, CodegenFail } {
        @setCold(true);
        assert(self.err_msg == null);
        const src_loc = @as(LazySrcLoc, .{ .node_offset = 0 }).toSrcLocWithDecl(self.decl);
        self.err_msg = try Module.ErrorMsg.create(self.gpa, src_loc, "TODO (LLVM): " ++ format, args);
        return error.CodegenFail;
    }

    fn llvmModule(self: *DeclGen) *const llvm.Module {
        return self.object.llvm_module;
    }

    fn genDecl(self: *DeclGen) !void {
        const decl = self.decl;
        assert(decl.has_tv);

        log.debug("gen: {s} type: {}, value: {}", .{ decl.name, decl.ty, decl.val });

        if (decl.val.castTag(.function)) |func_payload| {
            _ = func_payload;
            @panic("TODO llvm backend genDecl function pointer");
        } else if (decl.val.castTag(.extern_fn)) |extern_fn| {
            _ = try self.resolveLlvmFunction(extern_fn.data);
        } else {
            const global = try self.resolveGlobalDecl(decl);
            assert(decl.has_tv);
            const init_val = if (decl.val.castTag(.variable)) |payload| init_val: {
                const variable = payload.data;
                break :init_val variable.init;
            } else init_val: {
                global.setGlobalConstant(.True);
                break :init_val decl.val;
            };

            const llvm_init = try self.genTypedValue(.{ .ty = decl.ty, .val = init_val });
            llvm.setInitializer(global, llvm_init);
        }
    }

    /// If the llvm function does not exist, create it
    fn resolveLlvmFunction(self: *DeclGen, decl: *Module.Decl) !*const llvm.Value {
        if (self.llvmModule().getNamedFunction(decl.name)) |llvm_fn| return llvm_fn;

        assert(decl.has_tv);
        const zig_fn_type = decl.ty;
        const return_type = zig_fn_type.fnReturnType();
        const fn_param_len = zig_fn_type.fnParamLen();

        const fn_param_types = try self.gpa.alloc(Type, fn_param_len);
        defer self.gpa.free(fn_param_types);
        zig_fn_type.fnParamTypes(fn_param_types);

        const llvm_param = try self.gpa.alloc(*const llvm.Type, fn_param_len);
        defer self.gpa.free(llvm_param);

        for (fn_param_types) |fn_param, i| {
            llvm_param[i] = try self.llvmType(fn_param);
        }

        const fn_type = llvm.functionType(
            try self.llvmType(return_type),
            llvm_param.ptr,
            @intCast(c_uint, fn_param_len),
            .False,
        );
        const llvm_fn = self.llvmModule().addFunction(decl.name, fn_type);

        const is_extern = decl.val.tag() == .extern_fn;
        if (!is_extern) {
            llvm_fn.setLinkage(.Internal);
            llvm_fn.setUnnamedAddr(.True);
        }

        // TODO: calling convention, linkage, tsan, etc. see codegen.cpp `make_fn_llvm_value`.

        if (return_type.isNoReturn()) {
            self.addFnAttr(llvm_fn, "noreturn");
        }

        return llvm_fn;
    }

    fn resolveGlobalDecl(self: *DeclGen, decl: *Module.Decl) error{ OutOfMemory, CodegenFail }!*const llvm.Value {
        const llvm_module = self.object.llvm_module;
        if (llvm_module.getNamedGlobal(decl.name)) |val| return val;
        // TODO: remove this redundant `llvmType`, it is also called in `genTypedValue`.
        const llvm_type = try self.llvmType(decl.ty);
        return llvm_module.addGlobal(llvm_type, decl.name);
    }

    fn llvmType(self: *DeclGen, t: Type) error{ OutOfMemory, CodegenFail }!*const llvm.Type {
        log.debug("llvmType for {}", .{t});
        switch (t.zigTypeTag()) {
            .Void => return self.context.voidType(),
            .NoReturn => return self.context.voidType(),
            .Int => {
                const info = t.intInfo(self.module.getTarget());
                return self.context.intType(info.bits);
            },
            .Bool => return self.context.intType(1),
            .Pointer => {
                if (t.isSlice()) {
                    var buf: Type.Payload.ElemType = undefined;
                    const ptr_type = t.slicePtrFieldType(&buf);

                    const fields: [2]*const llvm.Type = .{
                        try self.llvmType(ptr_type),
                        try self.llvmType(Type.initTag(.usize)),
                    };
                    return self.context.structType(&fields, 2, .False);
                } else {
                    const elem_type = try self.llvmType(t.elemType());
                    return elem_type.pointerType(0);
                }
            },
            .Array => {
                const elem_type = try self.llvmType(t.elemType());
                const total_len = t.arrayLen() + @boolToInt(t.sentinel() != null);
                return elem_type.arrayType(@intCast(c_uint, total_len));
            },
            .Optional => {
                if (!t.isPtrLikeOptional()) {
                    var buf: Type.Payload.ElemType = undefined;
                    const child_type = t.optionalChild(&buf);

                    const optional_types: [2]*const llvm.Type = .{
                        try self.llvmType(child_type),
                        self.context.intType(1),
                    };
                    return self.context.structType(&optional_types, 2, .False);
                } else {
                    return self.todo("implement optional pointers as actual pointers", .{});
                }
            },
            .ErrorUnion => {
                const error_type = t.errorUnionSet();
                const payload_type = t.errorUnionPayload();
                if (!payload_type.hasCodeGenBits()) {
                    return self.llvmType(error_type);
                }
                return self.todo("implement llvmType for error unions", .{});
            },
            .ErrorSet => {
                return self.context.intType(16);
            },
            .Struct => {
                const struct_obj = t.castTag(.@"struct").?.data;
                assert(struct_obj.haveFieldTypes());
                const llvm_fields = try self.gpa.alloc(*const llvm.Type, struct_obj.fields.count());
                defer self.gpa.free(llvm_fields);
                for (struct_obj.fields.values()) |field, i| {
                    llvm_fields[i] = try self.llvmType(field.ty);
                }
                return self.context.structType(
                    llvm_fields.ptr,
                    @intCast(c_uint, llvm_fields.len),
                    .False,
                );
            },
            .Fn => {
                const ret_ty = try self.llvmType(t.fnReturnType());
                const params_len = t.fnParamLen();
                const llvm_params = try self.gpa.alloc(*const llvm.Type, params_len);
                defer self.gpa.free(llvm_params);
                for (llvm_params) |*llvm_param, i| {
                    llvm_param.* = try self.llvmType(t.fnParamType(i));
                }
                const is_var_args = t.fnIsVarArgs();
                const llvm_fn_ty = llvm.functionType(
                    ret_ty,
                    llvm_params.ptr,
                    @intCast(c_uint, llvm_params.len),
                    llvm.Bool.fromBool(is_var_args),
                );
                return llvm_fn_ty.pointerType(0);
            },
            .ComptimeInt => unreachable,
            .ComptimeFloat => unreachable,
            .Type => unreachable,
            .Undefined => unreachable,
            .Null => unreachable,
            .EnumLiteral => unreachable,

            .BoundFn => @panic("TODO remove BoundFn from the language"),

            .Float,
            .Enum,
            .Union,
            .Opaque,
            .Frame,
            .AnyFrame,
            .Vector,
            => return self.todo("implement llvmType for type '{}'", .{t}),
        }
    }

    fn genTypedValue(self: *DeclGen, tv: TypedValue) error{ OutOfMemory, CodegenFail }!*const llvm.Value {
        if (tv.val.isUndef()) {
            const llvm_type = try self.llvmType(tv.ty);
            return llvm_type.getUndef();
        }

        switch (tv.ty.zigTypeTag()) {
            .Bool => {
                const llvm_type = try self.llvmType(tv.ty);
                return if (tv.val.toBool()) llvm_type.constAllOnes() else llvm_type.constNull();
            },
            .Int => {
                var bigint_space: Value.BigIntSpace = undefined;
                const bigint = tv.val.toBigInt(&bigint_space);

                const llvm_type = try self.llvmType(tv.ty);
                if (bigint.eqZero()) return llvm_type.constNull();

                if (bigint.limbs.len != 1) {
                    return self.todo("implement bigger bigint", .{});
                }
                const llvm_int = llvm_type.constInt(bigint.limbs[0], .False);
                if (!bigint.positive) {
                    return llvm.constNeg(llvm_int);
                }
                return llvm_int;
            },
            .Pointer => switch (tv.val.tag()) {
                .decl_ref => {
                    const decl = tv.val.castTag(.decl_ref).?.data;
                    decl.alive = true;
                    const val = try self.resolveGlobalDecl(decl);
                    const llvm_type = try self.llvmType(tv.ty);
                    return val.constBitCast(llvm_type);
                },
                .variable => {
                    const decl = tv.val.castTag(.variable).?.data.owner_decl;
                    decl.alive = true;
                    const val = try self.resolveGlobalDecl(decl);
                    const llvm_var_type = try self.llvmType(tv.ty);
                    const llvm_type = llvm_var_type.pointerType(0);
                    return val.constBitCast(llvm_type);
                },
                .slice => {
                    const slice = tv.val.castTag(.slice).?.data;
                    var buf: Type.Payload.ElemType = undefined;
                    const fields: [2]*const llvm.Value = .{
                        try self.genTypedValue(.{
                            .ty = tv.ty.slicePtrFieldType(&buf),
                            .val = slice.ptr,
                        }),
                        try self.genTypedValue(.{
                            .ty = Type.initTag(.usize),
                            .val = slice.len,
                        }),
                    };
                    return self.context.constStruct(&fields, fields.len, .False);
                },
                else => |tag| return self.todo("implement const of pointer type '{}' ({})", .{ tv.ty, tag }),
            },
            .Array => {
                if (tv.val.castTag(.bytes)) |payload| {
                    const zero_sentinel = if (tv.ty.sentinel()) |sentinel| blk: {
                        if (sentinel.tag() == .zero) break :blk true;
                        return self.todo("handle other sentinel values", .{});
                    } else false;

                    return self.context.constString(
                        payload.data.ptr,
                        @intCast(c_uint, payload.data.len),
                        llvm.Bool.fromBool(!zero_sentinel),
                    );
                }
                if (tv.val.castTag(.array)) |payload| {
                    const gpa = self.gpa;
                    const elem_ty = tv.ty.elemType();
                    const elem_vals = payload.data;
                    const llvm_elems = try gpa.alloc(*const llvm.Value, elem_vals.len);
                    defer gpa.free(llvm_elems);
                    for (elem_vals) |elem_val, i| {
                        llvm_elems[i] = try self.genTypedValue(.{ .ty = elem_ty, .val = elem_val });
                    }
                    const llvm_elem_ty = try self.llvmType(elem_ty);
                    return llvm_elem_ty.constArray(
                        llvm_elems.ptr,
                        @intCast(c_uint, llvm_elems.len),
                    );
                }
                return self.todo("handle more array values", .{});
            },
            .Optional => {
                if (!tv.ty.isPtrLikeOptional()) {
                    var buf: Type.Payload.ElemType = undefined;
                    const child_type = tv.ty.optionalChild(&buf);
                    const llvm_child_type = try self.llvmType(child_type);

                    if (tv.val.tag() == .null_value) {
                        var optional_values: [2]*const llvm.Value = .{
                            llvm_child_type.constNull(),
                            self.context.intType(1).constNull(),
                        };
                        return self.context.constStruct(&optional_values, optional_values.len, .False);
                    } else {
                        var optional_values: [2]*const llvm.Value = .{
                            try self.genTypedValue(.{ .ty = child_type, .val = tv.val }),
                            self.context.intType(1).constAllOnes(),
                        };
                        return self.context.constStruct(&optional_values, optional_values.len, .False);
                    }
                } else {
                    return self.todo("implement const of optional pointer", .{});
                }
            },
            .Fn => {
                const fn_decl = switch (tv.val.tag()) {
                    .extern_fn => tv.val.castTag(.extern_fn).?.data,
                    .function => tv.val.castTag(.function).?.data.owner_decl,
                    .decl_ref => tv.val.castTag(.decl_ref).?.data,
                    else => unreachable,
                };
                fn_decl.alive = true;
                return self.resolveLlvmFunction(fn_decl);
            },
            .ErrorSet => {
                const llvm_ty = try self.llvmType(tv.ty);
                switch (tv.val.tag()) {
                    .@"error" => {
                        const err_name = tv.val.castTag(.@"error").?.data.name;
                        const kv = try self.module.getErrorValue(err_name);
                        return llvm_ty.constInt(kv.value, .False);
                    },
                    else => {
                        // In this case we are rendering an error union which has a 0 bits payload.
                        return llvm_ty.constNull();
                    },
                }
            },
            .ErrorUnion => {
                const error_type = tv.ty.errorUnionSet();
                const payload_type = tv.ty.errorUnionPayload();
                const sub_val = tv.val.castTag(.error_union).?.data;

                if (!payload_type.hasCodeGenBits()) {
                    // We use the error type directly as the type.
                    return self.genTypedValue(.{ .ty = error_type, .val = sub_val });
                }

                return self.todo("implement error union const of type '{}'", .{tv.ty});
            },
            .Struct => {
                const fields_len = tv.ty.structFieldCount();
                const field_vals = tv.val.castTag(.@"struct").?.data;
                const gpa = self.gpa;
                const llvm_fields = try gpa.alloc(*const llvm.Value, fields_len);
                defer gpa.free(llvm_fields);
                for (llvm_fields) |*llvm_field, i| {
                    llvm_field.* = try self.genTypedValue(.{
                        .ty = tv.ty.structFieldType(i),
                        .val = field_vals[i],
                    });
                }
                return self.context.constStruct(
                    llvm_fields.ptr,
                    @intCast(c_uint, llvm_fields.len),
                    .False,
                );
            },
            else => return self.todo("implement const of type '{}'", .{tv.ty}),
        }
    }

    // Helper functions
    fn addAttr(self: *DeclGen, val: *const llvm.Value, index: llvm.AttributeIndex, name: []const u8) void {
        const kind_id = llvm.getEnumAttributeKindForName(name.ptr, name.len);
        assert(kind_id != 0);
        const llvm_attr = self.context.createEnumAttribute(kind_id, 0);
        val.addAttributeAtIndex(index, llvm_attr);
    }

    fn addFnAttr(self: *DeclGen, val: *const llvm.Value, attr_name: []const u8) void {
        // TODO: improve this API, `addAttr(-1, attr_name)`
        self.addAttr(val, std.math.maxInt(llvm.AttributeIndex), attr_name);
    }
};

pub const FuncGen = struct {
    gpa: *Allocator,
    dg: *DeclGen,
    air: Air,
    liveness: Liveness,
    context: *const llvm.Context,

    builder: *const llvm.Builder,

    /// This stores the LLVM values used in a function, such that they can be referred to
    /// in other instructions. This table is cleared before every function is generated.
    func_inst_table: std.AutoHashMapUnmanaged(Air.Inst.Index, *const llvm.Value),

    /// These fields are used to refer to the LLVM value of the function paramaters
    /// in an Arg instruction.
    args: []*const llvm.Value,
    arg_index: usize,

    entry_block: *const llvm.BasicBlock,
    /// This fields stores the last alloca instruction, such that we can append
    /// more alloca instructions to the top of the function.
    latest_alloca_inst: ?*const llvm.Value,

    llvm_func: *const llvm.Value,

    /// This data structure is used to implement breaking to blocks.
    blocks: std.AutoHashMapUnmanaged(Air.Inst.Index, struct {
        parent_bb: *const llvm.BasicBlock,
        break_bbs: *BreakBasicBlocks,
        break_vals: *BreakValues,
    }),

    const BreakBasicBlocks = std.ArrayListUnmanaged(*const llvm.BasicBlock);
    const BreakValues = std.ArrayListUnmanaged(*const llvm.Value);

    fn deinit(self: *FuncGen) void {
        self.builder.dispose();
        self.func_inst_table.deinit(self.gpa);
        self.gpa.free(self.args);
        self.blocks.deinit(self.gpa);
    }

    fn todo(self: *FuncGen, comptime format: []const u8, args: anytype) error{ OutOfMemory, CodegenFail } {
        @setCold(true);
        return self.dg.todo(format, args);
    }

    fn llvmModule(self: *FuncGen) *const llvm.Module {
        return self.dg.object.llvm_module;
    }

    fn resolveInst(self: *FuncGen, inst: Air.Inst.Ref) !*const llvm.Value {
        if (self.air.value(inst)) |val| {
            return self.dg.genTypedValue(.{ .ty = self.air.typeOf(inst), .val = val });
        }
        const inst_index = Air.refToIndex(inst).?;
        return self.func_inst_table.get(inst_index).?;
    }

    fn genBody(self: *FuncGen, body: []const Air.Inst.Index) error{ OutOfMemory, CodegenFail }!void {
        const air_tags = self.air.instructions.items(.tag);
        for (body) |inst| {
            const opt_value: ?*const llvm.Value = switch (air_tags[inst]) {
                // zig fmt: off
                .add     => try self.airAdd(inst, false),
                .addwrap => try self.airAdd(inst, true),
                .sub     => try self.airSub(inst, false),
                .subwrap => try self.airSub(inst, true),
                .mul     => try self.airMul(inst, false),
                .mulwrap => try self.airMul(inst, true),
                .div     => try self.airDiv(inst),

                .bit_and, .bool_and => try self.airAnd(inst),
                .bit_or, .bool_or   => try self.airOr(inst),
                .xor                => try self.airXor(inst),

                .cmp_eq  => try self.airCmp(inst, .eq),
                .cmp_gt  => try self.airCmp(inst, .gt),
                .cmp_gte => try self.airCmp(inst, .gte),
                .cmp_lt  => try self.airCmp(inst, .lt),
                .cmp_lte => try self.airCmp(inst, .lte),
                .cmp_neq => try self.airCmp(inst, .neq),

                .is_non_null     => try self.airIsNonNull(inst, false),
                .is_non_null_ptr => try self.airIsNonNull(inst, true),
                .is_null         => try self.airIsNull(inst, false),
                .is_null_ptr     => try self.airIsNull(inst, true),
                .is_non_err      => try self.airIsErr(inst, true, false),
                .is_non_err_ptr  => try self.airIsErr(inst, true, true),
                .is_err          => try self.airIsErr(inst, false, false),
                .is_err_ptr      => try self.airIsErr(inst, false, true),

                .alloc      => try self.airAlloc(inst),
                .arg        => try self.airArg(inst),
                .bitcast    => try self.airBitCast(inst),
                .bool_to_int=> try self.airBoolToInt(inst),
                .block      => try self.airBlock(inst),
                .br         => try self.airBr(inst),
                .switch_br  => try self.airSwitchBr(inst),
                .breakpoint => try self.airBreakpoint(inst),
                .call       => try self.airCall(inst),
                .cond_br    => try self.airCondBr(inst),
                .intcast    => try self.airIntCast(inst),
                .trunc      => try self.airTrunc(inst),
                .floatcast  => try self.airFloatCast(inst),
                .ptrtoint   => try self.airPtrToInt(inst),
                .load       => try self.airLoad(inst),
                .loop       => try self.airLoop(inst),
                .not        => try self.airNot(inst),
                .ret        => try self.airRet(inst),
                .store      => try self.airStore(inst),
                .assembly   => try self.airAssembly(inst),
                .slice_ptr  => try self.airSliceField(inst, 0),
                .slice_len  => try self.airSliceField(inst, 1),

                .struct_field_ptr => try self.airStructFieldPtr(inst),
                .struct_field_val => try self.airStructFieldVal(inst),

                .slice_elem_val     => try self.airSliceElemVal(inst),
                .ptr_slice_elem_val => try self.airPtrSliceElemVal(inst),

                .optional_payload     => try self.airOptionalPayload(inst, false),
                .optional_payload_ptr => try self.airOptionalPayload(inst, true),

                .unwrap_errunion_payload     => try self.airErrUnionPayload(inst, false),
                .unwrap_errunion_payload_ptr => try self.airErrUnionPayload(inst, true),
                .unwrap_errunion_err         => try self.airErrUnionErr(inst, false),
                .unwrap_errunion_err_ptr     => try self.airErrUnionErr(inst, true),

                .wrap_optional         => try self.airWrapOptional(inst),
                .wrap_errunion_payload => try self.airWrapErrUnionPayload(inst),
                .wrap_errunion_err     => try self.airWrapErrUnionErr(inst),

                .constant => unreachable,
                .const_ty => unreachable,
                .unreach  => self.airUnreach(inst),
                .dbg_stmt => blk: {
                    // TODO: implement debug info
                    break :blk null;
                },
                // zig fmt: on
            };
            if (opt_value) |val| try self.func_inst_table.putNoClobber(self.gpa, inst, val);
        }
    }

    fn airCall(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const extra = self.air.extraData(Air.Call, pl_op.payload);
        const args = @bitCast([]const Air.Inst.Ref, self.air.extra[extra.end..][0..extra.data.args_len]);
        const zig_fn_type = self.air.typeOf(pl_op.operand);
        const return_type = zig_fn_type.fnReturnType();
        const llvm_fn = try self.resolveInst(pl_op.operand);

        const llvm_param_vals = try self.gpa.alloc(*const llvm.Value, args.len);
        defer self.gpa.free(llvm_param_vals);

        for (args) |arg, i| {
            llvm_param_vals[i] = try self.resolveInst(arg);
        }

        const call = self.builder.buildCall(
            llvm_fn,
            llvm_param_vals.ptr,
            @intCast(c_uint, args.len),
            "",
        );

        if (return_type.isNoReturn()) {
            _ = self.builder.buildUnreachable();
        }

        // No need to store the LLVM value if the return type is void or noreturn
        if (!return_type.hasCodeGenBits()) return null;

        return call;
    }

    fn airRet(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const un_op = self.air.instructions.items(.data)[inst].un_op;
        if (!self.air.typeOf(un_op).hasCodeGenBits()) {
            _ = self.builder.buildRetVoid();
            return null;
        }
        const operand = try self.resolveInst(un_op);
        _ = self.builder.buildRet(operand);
        return null;
    }

    fn airCmp(self: *FuncGen, inst: Air.Inst.Index, op: math.CompareOperator) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.air.typeOfIndex(inst);

        if (!inst_ty.isInt())
            if (inst_ty.tag() != .bool)
                return self.todo("implement 'airCmp' for type {}", .{inst_ty});

        const is_signed = inst_ty.isSignedInt();
        const operation = switch (op) {
            .eq => .EQ,
            .neq => .NE,
            .lt => @as(llvm.IntPredicate, if (is_signed) .SLT else .ULT),
            .lte => @as(llvm.IntPredicate, if (is_signed) .SLE else .ULE),
            .gt => @as(llvm.IntPredicate, if (is_signed) .SGT else .UGT),
            .gte => @as(llvm.IntPredicate, if (is_signed) .SGE else .UGE),
        };

        return self.builder.buildICmp(operation, lhs, rhs, "");
    }

    fn airBlock(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const extra = self.air.extraData(Air.Block, ty_pl.payload);
        const body = self.air.extra[extra.end..][0..extra.data.body_len];
        const parent_bb = self.context.createBasicBlock("Block");

        // 5 breaks to a block seems like a reasonable default.
        var break_bbs = try BreakBasicBlocks.initCapacity(self.gpa, 5);
        var break_vals = try BreakValues.initCapacity(self.gpa, 5);
        try self.blocks.putNoClobber(self.gpa, inst, .{
            .parent_bb = parent_bb,
            .break_bbs = &break_bbs,
            .break_vals = &break_vals,
        });
        defer {
            assert(self.blocks.remove(inst));
            break_bbs.deinit(self.gpa);
            break_vals.deinit(self.gpa);
        }

        try self.genBody(body);

        self.llvm_func.appendExistingBasicBlock(parent_bb);
        self.builder.positionBuilderAtEnd(parent_bb);

        // If the block does not return a value, we dont have to create a phi node.
        const inst_ty = self.air.typeOfIndex(inst);
        if (!inst_ty.hasCodeGenBits()) return null;

        const phi_node = self.builder.buildPhi(try self.dg.llvmType(inst_ty), "");
        phi_node.addIncoming(
            break_vals.items.ptr,
            break_bbs.items.ptr,
            @intCast(c_uint, break_vals.items.len),
        );
        return phi_node;
    }

    fn airBr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const branch = self.air.instructions.items(.data)[inst].br;
        const block = self.blocks.get(branch.block_inst).?;

        // If the break doesn't break a value, then we don't have to add
        // the values to the lists.
        if (self.air.typeOf(branch.operand).hasCodeGenBits()) {
            const val = try self.resolveInst(branch.operand);

            // For the phi node, we need the basic blocks and the values of the
            // break instructions.
            try block.break_bbs.append(self.gpa, self.builder.getInsertBlock());
            try block.break_vals.append(self.gpa, val);
        }
        _ = self.builder.buildBr(block.parent_bb);
        return null;
    }

    fn airCondBr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const pl_op = self.air.instructions.items(.data)[inst].pl_op;
        const cond = try self.resolveInst(pl_op.operand);
        const extra = self.air.extraData(Air.CondBr, pl_op.payload);
        const then_body = self.air.extra[extra.end..][0..extra.data.then_body_len];
        const else_body = self.air.extra[extra.end + then_body.len ..][0..extra.data.else_body_len];

        const then_block = self.context.appendBasicBlock(self.llvm_func, "Then");
        const else_block = self.context.appendBasicBlock(self.llvm_func, "Else");
        {
            const prev_block = self.builder.getInsertBlock();
            defer self.builder.positionBuilderAtEnd(prev_block);

            self.builder.positionBuilderAtEnd(then_block);
            try self.genBody(then_body);

            self.builder.positionBuilderAtEnd(else_block);
            try self.genBody(else_body);
        }
        _ = self.builder.buildCondBr(cond, then_block, else_block);
        return null;
    }

    fn airSwitchBr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        _ = inst;
        return self.todo("implement llvm codegen for switch_br", .{});
    }

    fn airLoop(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const loop = self.air.extraData(Air.Block, ty_pl.payload);
        const body = self.air.extra[loop.end..][0..loop.data.body_len];
        const loop_block = self.context.appendBasicBlock(self.llvm_func, "Loop");
        _ = self.builder.buildBr(loop_block);

        self.builder.positionBuilderAtEnd(loop_block);
        try self.genBody(body);

        _ = self.builder.buildBr(loop_block);
        return null;
    }

    fn airSliceField(self: *FuncGen, inst: Air.Inst.Index, index: c_uint) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        return self.builder.buildExtractValue(operand, index, "");
    }

    fn airSliceElemVal(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const base_ptr = self.builder.buildExtractValue(lhs, 0, "");
        const indices: [1]*const llvm.Value = .{rhs};
        const ptr = self.builder.buildInBoundsGEP(base_ptr, &indices, indices.len, "");
        return self.builder.buildLoad(ptr, "");
    }

    fn airPtrSliceElemVal(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);

        const base_ptr = ptr: {
            const index_type = self.context.intType(32);
            const indices: [2]*const llvm.Value = .{
                index_type.constNull(),
                index_type.constInt(0, .False),
            };
            const ptr_field_ptr = self.builder.buildInBoundsGEP(lhs, &indices, 2, "");
            break :ptr self.builder.buildLoad(ptr_field_ptr, "");
        };

        const indices: [1]*const llvm.Value = .{rhs};
        const ptr = self.builder.buildInBoundsGEP(base_ptr, &indices, indices.len, "");
        return self.builder.buildLoad(ptr, "");
    }

    fn airStructFieldPtr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;
        const struct_ptr = try self.resolveInst(struct_field.struct_operand);
        const field_index = @intCast(c_uint, struct_field.field_index);
        return self.builder.buildStructGEP(struct_ptr, field_index, "");
    }

    fn airStructFieldVal(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const struct_field = self.air.extraData(Air.StructField, ty_pl.payload).data;
        const struct_byval = try self.resolveInst(struct_field.struct_operand);
        const field_index = @intCast(c_uint, struct_field.field_index);
        return self.builder.buildExtractValue(struct_byval, field_index, "");
    }

    fn airNot(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);

        return self.builder.buildNot(operand, "");
    }

    fn airUnreach(self: *FuncGen, inst: Air.Inst.Index) ?*const llvm.Value {
        _ = inst;
        _ = self.builder.buildUnreachable();
        return null;
    }

    fn airAssembly(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        // Eventually, the Zig compiler needs to be reworked to have inline assembly go
        // through the same parsing code regardless of backend, and have LLVM-flavored
        // inline assembly be *output* from that assembler.
        // We don't have such an assembler implemented yet though. For now, this
        // implementation feeds the inline assembly code directly to LLVM, same
        // as stage1.

        const ty_pl = self.air.instructions.items(.data)[inst].ty_pl;
        const air_asm = self.air.extraData(Air.Asm, ty_pl.payload);
        const zir = self.dg.decl.namespace.file_scope.zir;
        const extended = zir.instructions.items(.data)[air_asm.data.zir_index].extended;
        const zir_extra = zir.extraData(Zir.Inst.Asm, extended.operand);
        const asm_source = zir.nullTerminatedString(zir_extra.data.asm_source);
        const outputs_len = @truncate(u5, extended.small);
        const args_len = @truncate(u5, extended.small >> 5);
        const clobbers_len = @truncate(u5, extended.small >> 10);
        const is_volatile = @truncate(u1, extended.small >> 15) != 0;
        const outputs = @bitCast([]const Air.Inst.Ref, self.air.extra[air_asm.end..][0..outputs_len]);
        const args = @bitCast([]const Air.Inst.Ref, self.air.extra[air_asm.end + outputs.len ..][0..args_len]);
        if (outputs_len > 1) {
            return self.todo("implement llvm codegen for asm with more than 1 output", .{});
        }

        var extra_i: usize = zir_extra.end;
        const output_constraint: ?[]const u8 = out: {
            var i: usize = 0;
            while (i < outputs_len) : (i += 1) {
                const output = zir.extraData(Zir.Inst.Asm.Output, extra_i);
                extra_i = output.end;
                break :out zir.nullTerminatedString(output.data.constraint);
            }
            break :out null;
        };

        if (!is_volatile and self.liveness.isUnused(inst)) {
            return null;
        }

        var llvm_constraints: std.ArrayListUnmanaged(u8) = .{};
        defer llvm_constraints.deinit(self.gpa);

        var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_allocator.deinit();
        const arena = &arena_allocator.allocator;

        const llvm_params_len = args.len + @boolToInt(output_constraint != null);
        const llvm_param_types = try arena.alloc(*const llvm.Type, llvm_params_len);
        const llvm_param_values = try arena.alloc(*const llvm.Value, llvm_params_len);

        var llvm_param_i: usize = 0;
        var total_i: usize = 0;

        if (output_constraint) |constraint| {
            try llvm_constraints.ensureUnusedCapacity(self.gpa, constraint.len + 1);
            if (total_i != 0) {
                llvm_constraints.appendAssumeCapacity(',');
            }
            llvm_constraints.appendSliceAssumeCapacity(constraint);

            total_i += 1;
        }

        for (args) |arg| {
            const input = zir.extraData(Zir.Inst.Asm.Input, extra_i);
            extra_i = input.end;
            const constraint = zir.nullTerminatedString(input.data.constraint);
            const arg_llvm_value = try self.resolveInst(arg);

            llvm_param_values[llvm_param_i] = arg_llvm_value;
            llvm_param_types[llvm_param_i] = arg_llvm_value.typeOf();

            try llvm_constraints.ensureUnusedCapacity(self.gpa, constraint.len + 1);
            if (total_i != 0) {
                llvm_constraints.appendAssumeCapacity(',');
            }
            llvm_constraints.appendSliceAssumeCapacity(constraint);

            llvm_param_i += 1;
            total_i += 1;
        }

        const clobbers = zir.extra[extra_i..][0..clobbers_len];
        for (clobbers) |clobber_index| {
            const clobber = zir.nullTerminatedString(clobber_index);
            try llvm_constraints.ensureUnusedCapacity(self.gpa, clobber.len + 4);
            if (total_i != 0) {
                llvm_constraints.appendAssumeCapacity(',');
            }
            llvm_constraints.appendSliceAssumeCapacity("~{");
            llvm_constraints.appendSliceAssumeCapacity(clobber);
            llvm_constraints.appendSliceAssumeCapacity("}");

            total_i += 1;
        }

        const ret_ty = self.air.typeOfIndex(inst);
        const ret_llvm_ty = try self.dg.llvmType(ret_ty);
        const llvm_fn_ty = llvm.functionType(
            ret_llvm_ty,
            llvm_param_types.ptr,
            @intCast(c_uint, llvm_param_types.len),
            .False,
        );
        const asm_fn = llvm.getInlineAsm(
            llvm_fn_ty,
            asm_source.ptr,
            asm_source.len,
            llvm_constraints.items.ptr,
            llvm_constraints.items.len,
            llvm.Bool.fromBool(is_volatile),
            .False,
            .ATT,
        );
        return self.builder.buildCall(
            asm_fn,
            llvm_param_values.ptr,
            @intCast(c_uint, llvm_param_values.len),
            "",
        );
    }

    fn airIsNonNull(self: *FuncGen, inst: Air.Inst.Index, operand_is_ptr: bool) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);

        if (operand_is_ptr) {
            const index_type = self.context.intType(32);

            var indices: [2]*const llvm.Value = .{
                index_type.constNull(),
                index_type.constInt(1, .False),
            };

            return self.builder.buildLoad(self.builder.buildInBoundsGEP(operand, &indices, 2, ""), "");
        } else {
            return self.builder.buildExtractValue(operand, 1, "");
        }
    }

    fn airIsNull(self: *FuncGen, inst: Air.Inst.Index, operand_is_ptr: bool) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        return self.builder.buildNot((try self.airIsNonNull(inst, operand_is_ptr)).?, "");
    }

    fn airIsErr(
        self: *FuncGen,
        inst: Air.Inst.Index,
        invert_logic: bool,
        operand_is_ptr: bool,
    ) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const err_union_ty = self.air.typeOf(un_op);
        const payload_ty = err_union_ty.errorUnionPayload();

        if (!payload_ty.hasCodeGenBits()) {
            const loaded = if (operand_is_ptr) self.builder.buildLoad(operand, "") else operand;
            const op: llvm.IntPredicate = if (invert_logic) .EQ else .NE;
            const err_set_ty = try self.dg.llvmType(Type.initTag(.anyerror));
            const zero = err_set_ty.constNull();
            return self.builder.buildICmp(op, loaded, zero, "");
        }

        return self.todo("implement 'airIsErr' for error unions with nonzero payload", .{});
    }

    fn airOptionalPayload(
        self: *FuncGen,
        inst: Air.Inst.Index,
        operand_is_ptr: bool,
    ) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);

        if (operand_is_ptr) {
            const index_type = self.context.intType(32);

            var indices: [2]*const llvm.Value = .{
                index_type.constNull(),
                index_type.constNull(),
            };

            return self.builder.buildInBoundsGEP(operand, &indices, 2, "");
        } else {
            return self.builder.buildExtractValue(operand, 0, "");
        }
    }

    fn airErrUnionPayload(
        self: *FuncGen,
        inst: Air.Inst.Index,
        operand_is_ptr: bool,
    ) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const err_union_ty = self.air.typeOf(ty_op.operand);
        const payload_ty = err_union_ty.errorUnionPayload();

        if (!payload_ty.hasCodeGenBits()) {
            return null;
        }

        _ = operand;
        _ = operand_is_ptr;
        return self.todo("implement llvm codegen for 'airErrUnionPayload' for type {}", .{self.air.typeOf(ty_op.operand)});
    }

    fn airErrUnionErr(
        self: *FuncGen,
        inst: Air.Inst.Index,
        operand_is_ptr: bool,
    ) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const operand_ty = self.air.typeOf(ty_op.operand);

        const payload_ty = operand_ty.errorUnionPayload();
        if (!payload_ty.hasCodeGenBits()) {
            if (!operand_is_ptr) return operand;
            return self.builder.buildLoad(operand, "");
        }
        return self.todo("implement llvm codegen for 'airErrUnionErr'", .{});
    }

    fn airWrapOptional(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        return self.todo("implement llvm codegen for 'airWrapOptional'", .{});
    }

    fn airWrapErrUnionPayload(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        return self.todo("implement llvm codegen for 'airWrapErrUnionPayload'", .{});
    }

    fn airWrapErrUnionErr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        return self.todo("implement llvm codegen for 'airWrapErrUnionErr'", .{});
    }

    fn airAdd(self: *FuncGen, inst: Air.Inst.Index, wrap: bool) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.air.typeOfIndex(inst);

        if (inst_ty.isFloat()) return self.builder.buildFAdd(lhs, rhs, "");
        if (wrap) return self.builder.buildAdd(lhs, rhs, "");
        if (inst_ty.isSignedInt()) return self.builder.buildNSWAdd(lhs, rhs, "");
        return self.builder.buildNUWAdd(lhs, rhs, "");
    }

    fn airSub(self: *FuncGen, inst: Air.Inst.Index, wrap: bool) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.air.typeOfIndex(inst);

        if (inst_ty.isFloat()) return self.builder.buildFSub(lhs, rhs, "");
        if (wrap) return self.builder.buildSub(lhs, rhs, "");
        if (inst_ty.isSignedInt()) return self.builder.buildNSWSub(lhs, rhs, "");
        return self.builder.buildNUWSub(lhs, rhs, "");
    }

    fn airMul(self: *FuncGen, inst: Air.Inst.Index, wrap: bool) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.air.typeOfIndex(inst);

        if (inst_ty.isFloat()) return self.builder.buildFMul(lhs, rhs, "");
        if (wrap) return self.builder.buildMul(lhs, rhs, "");
        if (inst_ty.isSignedInt()) return self.builder.buildNSWMul(lhs, rhs, "");
        return self.builder.buildNUWMul(lhs, rhs, "");
    }

    fn airDiv(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        const inst_ty = self.air.typeOfIndex(inst);

        if (inst_ty.isFloat()) return self.builder.buildFDiv(lhs, rhs, "");
        if (inst_ty.isSignedInt()) return self.builder.buildSDiv(lhs, rhs, "");
        return self.builder.buildUDiv(lhs, rhs, "");
    }

    fn airAnd(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildAnd(lhs, rhs, "");
    }

    fn airOr(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildOr(lhs, rhs, "");
    }

    fn airXor(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const lhs = try self.resolveInst(bin_op.lhs);
        const rhs = try self.resolveInst(bin_op.rhs);
        return self.builder.buildXor(lhs, rhs, "");
    }

    fn airIntCast(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const inst_ty = self.air.typeOfIndex(inst);

        const signed = inst_ty.isSignedInt();
        // TODO: Should we use intcast here or just a simple bitcast?
        //       LLVM does truncation vs bitcast (+signed extension) in the intcast depending on the sizes
        return self.builder.buildIntCast2(operand, try self.dg.llvmType(inst_ty), llvm.Bool.fromBool(signed), "");
    }

    fn airTrunc(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const dest_llvm_ty = try self.dg.llvmType(self.air.typeOfIndex(inst));
        return self.builder.buildTrunc(operand, dest_llvm_ty, "");
    }

    fn airFloatCast(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        // TODO split floatcast AIR into float_widen and float_shorten
        return self.todo("implement 'airFloatCast'", .{});
    }

    fn airPtrToInt(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        const dest_llvm_ty = try self.dg.llvmType(self.air.typeOfIndex(inst));
        return self.builder.buildPtrToInt(operand, dest_llvm_ty, "");
    }

    fn airBitCast(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const operand = try self.resolveInst(ty_op.operand);
        const inst_ty = self.air.typeOfIndex(inst);
        const dest_type = try self.dg.llvmType(inst_ty);

        return self.builder.buildBitCast(operand, dest_type, "");
    }

    fn airBoolToInt(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;

        const un_op = self.air.instructions.items(.data)[inst].un_op;
        const operand = try self.resolveInst(un_op);
        return operand;
    }

    fn airArg(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const arg_val = self.args[self.arg_index];
        self.arg_index += 1;

        const inst_ty = self.air.typeOfIndex(inst);
        const ptr_val = self.buildAlloca(try self.dg.llvmType(inst_ty));
        _ = self.builder.buildStore(arg_val, ptr_val);
        return self.builder.buildLoad(ptr_val, "");
    }

    fn airAlloc(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        if (self.liveness.isUnused(inst))
            return null;
        // buildAlloca expects the pointee type, not the pointer type, so assert that
        // a Payload.PointerSimple is passed to the alloc instruction.
        const inst_ty = self.air.typeOfIndex(inst);
        const pointee_type = inst_ty.castPointer().?.data;

        // TODO: figure out a way to get the name of the var decl.
        // TODO: set alignment and volatile
        return self.buildAlloca(try self.dg.llvmType(pointee_type));
    }

    /// Use this instead of builder.buildAlloca, because this function makes sure to
    /// put the alloca instruction at the top of the function!
    fn buildAlloca(self: *FuncGen, t: *const llvm.Type) *const llvm.Value {
        const prev_block = self.builder.getInsertBlock();
        defer self.builder.positionBuilderAtEnd(prev_block);

        if (self.latest_alloca_inst) |latest_alloc| {
            // builder.positionBuilder adds it before the instruction,
            // but we want to put it after the last alloca instruction.
            self.builder.positionBuilder(self.entry_block, latest_alloc.getNextInstruction().?);
        } else {
            // There might have been other instructions emitted before the
            // first alloca has been generated. However the alloca should still
            // be first in the function.
            if (self.entry_block.getFirstInstruction()) |first_inst| {
                self.builder.positionBuilder(self.entry_block, first_inst);
            }
        }

        const val = self.builder.buildAlloca(t, "");
        self.latest_alloca_inst = val;
        return val;
    }

    fn airStore(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const bin_op = self.air.instructions.items(.data)[inst].bin_op;
        const dest_ptr = try self.resolveInst(bin_op.lhs);
        const src_operand = try self.resolveInst(bin_op.rhs);
        // TODO set volatile on this store properly
        _ = self.builder.buildStore(src_operand, dest_ptr);
        return null;
    }

    fn airLoad(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        const ty_op = self.air.instructions.items(.data)[inst].ty_op;
        const is_volatile = self.air.typeOf(ty_op.operand).isVolatilePtr();
        if (!is_volatile and self.liveness.isUnused(inst))
            return null;
        const ptr = try self.resolveInst(ty_op.operand);
        // TODO set volatile on this load properly
        return self.builder.buildLoad(ptr, "");
    }

    fn airBreakpoint(self: *FuncGen, inst: Air.Inst.Index) !?*const llvm.Value {
        _ = inst;
        const llvm_fn = self.getIntrinsic("llvm.debugtrap");
        _ = self.builder.buildCall(llvm_fn, undefined, 0, "");
        return null;
    }

    fn getIntrinsic(self: *FuncGen, name: []const u8) *const llvm.Value {
        const id = llvm.lookupIntrinsicID(name.ptr, name.len);
        assert(id != 0);
        // TODO: add support for overload intrinsics by passing the prefix of the intrinsic
        //       to `lookupIntrinsicID` and then passing the correct types to
        //       `getIntrinsicDeclaration`
        return self.llvmModule().getIntrinsicDeclaration(id, null, 0);
    }
};
