const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ast = std.c.ast;
const Node = ast.Node;
const Tree = ast.Tree;
const TokenIndex = ast.TokenIndex;
const Token = std.c.Token;
const TokenIterator = ast.Tree.TokenList.Iterator;

pub const Error = error{ParseError} || Allocator.Error;

/// Result should be freed with tree.deinit() when there are
/// no more references to any of the tokens or nodes.
pub fn parse(allocator: *Allocator, source: []const u8) !*Tree {
    const tree = blk: {
        // This block looks unnecessary, but is a "foot-shield" to prevent the SegmentedLists
        // from being initialized with a pointer to this `arena`, which is created on
        // the stack. Following code should instead refer to `&tree.arena_allocator`, a
        // pointer to data which lives safely on the heap and will outlive `parse`.
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const tree = try arena.allocator.create(ast.Tree);
        tree.* = .{
            .root_node = undefined,
            .arena_allocator = arena,
            .tokens = undefined,
            .sources = undefined,
        };
        break :blk tree;
    };
    errdefer tree.deinit();
    const arena = &tree.arena_allocator.allocator;

    tree.tokens = ast.Tree.TokenList.init(arena);
    tree.sources = ast.Tree.SourceList.init(arena);

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const tree_token = try tree.tokens.addOne();
        tree_token.* = tokenizer.next();
        if (tree_token.id == .Eof) break;
    }
    // TODO preprocess here
    var it = tree.tokens.iterator(0);

    while (true) {
        const tok = it.peek().?.id;
        switch (id) {
            .LineComment,
            .MultiLineComment,
            => {
                _ = it.next();
            },
            else => break,
        }
    }

    var parser = Parser{
        .arena = arena,
        .it = &it,
        .tree = tree,
    };

    tree.root_node = try parser.root();
    return tree;
}

const Parser = struct {
    arena: *Allocator,
    it: *TokenIterator,
    tree: *Tree,
    typedefs: std.StringHashMap(void),

    fn isTypedef(parser: *Parser, tok: TokenIndex) bool {
        const token = parser.it.list.at(tok);
        return parser.typedefs.contains(token.slice());
    }

    /// Root <- ExternalDeclaration* eof
    fn root(parser: *Parser) Allocator.Error!*Node {
        const node = try arena.create(ast.Root);
        node.* = .{
            .decls = ast.Node.DeclList.init(arena),
            .eof = undefined,
        };
        while (parser.externalDeclarations() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return node,
        }) |decl| {
            try node.decls.push(decl);
        }
        node.eof = eatToken(it, .Eof) orelse {
            try tree.errors.push(.{
                .ExpectedDecl = .{ .token = it.index },
            });
            return node;
        };
        return node;
    }

    /// ExternalDeclaration
    ///     <- DeclSpec Declarator Declaration* CompoundStmt
    ///     / DeclSpec (Declarator (EQUAL Initializer)?)* SEMICOLON
    ///     / StaticAssert
    fn externalDeclarations(parser: *Parser) !?*Node {
        if (try Declaration(parser)) |decl| {}
        return null;
    }

    /// Declaration
    ///     <- DeclSpec (Declarator (EQUAL Initializer)?)* SEMICOLON
    ///     / StaticAssert
    fn declaration(parser: *Parser) !?*Node {}

    /// StaticAssert <- Keyword_static_assert LPAREN ConstExpr COMMA STRINGLITERAL RPAREN SEMICOLON
    fn StaticAssert(parser: *Parser) !?*Node {}

    /// DeclSpec <- (StorageClassSpec / TypeSpec / FnSpec / AlignSpec)*
    fn declSpec(parser: *Parser) !*Node.DeclSpec {
        const ds = try parser.arena.create(Node.DeclSpec);
        ds.* = .{};
        while ((try parser.storageClassSpec(ds)) or (try parser.typeSpec(&ds.type_spec)) or (try parser.fnSpec(ds)) or (try parser.alignSpec(ds))) {}
        return ds;
    }

    /// StorageClassSpec
    ///     <- Keyword_typedef / Keyword_extern / Keyword_static / Keyword_thread_local / Keyword_auto / Keyword_register
    fn storageClassSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        blk: {
            if (parser.eatToken(.Keyword_typedef)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Typedef = tok };
            } else if (parser.eatToken(.Keyword_extern)) |tok| {
                if (ds.storage_class != .None)
                    break :blk;
                ds.storage_class = .{ .Extern = tok };
            } else if (parser.eatToken(.Keyword_static)) |tok| {
                if (ds.storage_class != .None)
                    break :blk;
                ds.storage_class = .{ .Static = tok };
            } else if (parser.eatToken(.Keyword_thread_local)) |tok| {
                switch (ds.storage_class) {
                    .None, .Extern, .Static => {},
                    else => break :blk,
                }
                ds.thread_local = tok;
            } else if (parser.eatToken(.Keyword_auto)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Auto = tok };
            } else if (parser.eatToken(.Keyword_register)) |tok| {
                if (ds.storage_class != .None or ds.thread_local != null)
                    break :blk;
                ds.storage_class = .{ .Register = tok };
            } else return false;
            return true;
        }
        try parser.warning(.{
            .DuplicateSpecifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// TypeSpec
    ///     <- Keyword_void / Keyword_char / Keyword_short / Keyword_int / Keyword_long / Keyword_float / Keyword_double
    ///     / Keyword_signed / Keyword_unsigned / Keyword_bool / Keyword_complex / Keyword_imaginary /
    ///     / Keyword_atomic LPAREN TypeName RPAREN
    ///     / EnumSpecifier
    ///     / RecordSpecifier
    ///     / IDENTIFIER // typedef name
    ///     / TypeQual
    fn typeSpec(parser: *Parser, type_spec: *Node.TypeSpec) !bool {
        while (try parser.typeQual(&type_spec.qual)) {}
        blk: {
            if (parser.eatToken(.Keyword_void)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{ .Void = tok };
                return true;
            } else if (parser.eatToken(.Keyword_char)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Char = .{
                                .char = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        if (int.int != null)
                            break :blk;
                        type_spec.spec = .{
                            .Char = .{
                                .char = tok,
                                .sign = int.sign,
                            },
                        };
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_short)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Short = .{
                                .short = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        if (int.int != null)
                            break :blk;
                        type_spec.spec = .{
                            .Short = .{
                                .short = tok,
                                .sign = int.sign,
                            },
                        };
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_long)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Long = .{
                                .long = tok,
                            },
                        };
                    },
                    .Int => |int| {
                        type_spec.spec = .{
                            .Long = .{
                                .long = tok,
                                .sign = int.sign,
                                .int = int.int,
                            },
                        };
                    },
                    .Long => |*long| {
                        if (long.longlong != null)
                            break :blk;
                        long.longlong = tok;
                    },
                    .Double => |*double| {
                        if (double.long != null)
                            break :blk;
                        double.long = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_int)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Int = .{
                                .int = tok,
                            },
                        };
                    },
                    .Short => |*short| {
                        if (short.int != null)
                            break :blk;
                        short.int = tok;
                    },
                    .Int => |*int| {
                        if (int.int != null)
                            break :blk;
                        int.int = tok;
                    },
                    .Long => |*long| {
                        if (long.int != null)
                            break :blk;
                        long.int = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_signed) orelse parser.eatToken(.Keyword_unsigned)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Int = .{
                                .sign = tok,
                            },
                        };
                    },
                    .Char => |*char| {
                        if (char.sign != null)
                            break :blk;
                        char.sign = tok;
                    },
                    .Short => |*short| {
                        if (short.sign != null)
                            break :blk;
                        short.sign = tok;
                    },
                    .Int => |*int| {
                        if (int.sign != null)
                            break :blk;
                        int.sign = tok;
                    },
                    .Long => |*long| {
                        if (long.sign != null)
                            break :blk;
                        long.sign = tok;
                    },
                    else => break :blk,
                }
                return true;
            } else if (parser.eatToken(.Keyword_float)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{
                    .Float = .{
                        .float = tok,
                    },
                };
                return true;
            } else if (parser.eatToken(.Keyword_double)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{
                    .Double = .{
                        .double = tok,
                    },
                };
                return true;
            } else if (parser.eatToken(.Keyword_complex)) |tok| {
                switch (type_spec.spec) {
                    .None => {
                        type_spec.spec = .{
                            .Double = .{
                                .complex = tok,
                                .double = null,
                            },
                        };
                    },
                    .Float => |*float| {
                        if (float.complex != null)
                            break :blk;
                        float.complex = tok;
                    },
                    .Double => |*double| {
                        if (double.complex != null)
                            break :blk;
                        double.complex = tok;
                    },
                    else => break :blk,
                }
                return true;
            }
            if (parser.eatToken(.Keyword_bool)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                type_spec.spec = .{ .Bool = tok };
                return true;
            } else if (parser.eatToken(.Keyword_atomic)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                _ = try parser.expectToken(.LParen);
                const name = try parser.expect(typeName, .{
                    .ExpectedTypeName = .{ .token = parser.it.index },
                });
                type_spec.spec.Atomic = .{
                    .atomic = tok,
                    .typename = name,
                    .rparen = try parser.expectToken(.RParen),
                };
                return true;
            } else if (parser.eatToken(.Keyword_enum)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                @panic("TODO enum type");
                // return true;
            } else if (parser.eatToken(.Keyword_union) orelse parser.eatToken(.Keyword_struct)) |tok| {
                if (type_spec.spec != .None)
                    break :blk;
                @panic("TODO record type");
                // return true;
            } else if (parser.eatToken(.Identifier)) |tok| {
                if (!parser.isTypedef(tok)) {
                    parser.putBackToken(tok);
                    return false;
                }
                type_spec.spec = .{
                    .Typedef = tok,
                };
                return true;
            }
        }
        try parser.tree.errors.push(.{
            .InvalidTypeSpecifier = .{
                .token = parser.it.index,
                .type_spec = type_spec,
            },
        });
        return error.ParseError;
    }

    /// TypeQual <- Keyword_const / Keyword_restrict / Keyword_volatile / Keyword_atomic
    fn typeQual(parser: *Parser, qual: *Node.TypeQual) !bool {
        blk: {
            if (parser.eatToken(.Keyword_const)) |tok| {
                if (qual.@"const" != null)
                    break :blk;
                qual.@"const" = tok;
            } else if (parser.eatToken(.Keyword_restrict)) |tok| {
                if (qual.atomic != null)
                    break :blk;
                qual.atomic = tok;
            } else if (parser.eatToken(.Keyword_volatile)) |tok| {
                if (qual.@"volatile" != null)
                    break :blk;
                qual.@"volatile" = tok;
            } else if (parser.eatToken(.Keyword_atomic)) |tok| {
                if (qual.atomic != null)
                    break :blk;
                qual.atomic = tok;
            } else return false;
            return true;
        }
        try parser.warning(.{
            .DuplicateQualifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// FnSpec <- Keyword_inline / Keyword_noreturn
    fn fnSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        blk: {
            if (parser.eatToken(.Keyword_inline)) |tok| {
                if (ds.fn_spec != .None)
                    break :blk;
                ds.fn_spec = .{ .Inline = tok };
            } else if (parser.eatToken(.Keyword_noreturn)) |tok| {
                if (ds.fn_spec != .None)
                    break :blk;
                ds.fn_spec = .{ .Noreturn = tok };
            } else return false;
            return true;
        }
        try parser.warning(.{
            .DuplicateSpecifier = .{ .token = parser.it.index },
        });
        return true;
    }

    /// AlignSpec <- Keyword_alignas LPAREN (TypeName / ConstExpr) RPAREN
    fn alignSpec(parser: *Parser, ds: *Node.DeclSpec) !bool {
        if (parser.eatToken(.Keyword_alignas)) |tok| {
            _ = try parser.expectToken(.LParen);
            const node = (try parser.typeName()) orelse (try parser.expect(conditionalExpr, .{
                .ExpectedExpr = .{ .token = parser.it.index },
            }));
            if (ds.align_spec != null) {
                try parser.warning(.{
                    .DuplicateSpecifier = .{ .token = parser.it.index },
                });
            }
            ds.align_spec = .{
                .alignas = tok,
                .expr = node,
                .rparen = try parser.expectToken(.RParen),
            };
            return true;
        }
        return false;
    }

    /// EnumSpecifier <- Keyword_enum IDENTIFIER? (LBRACE EnumField RBRACE)?
    fn enumSpecifier(parser: *Parser) !*Node {}

    /// EnumField <- IDENTIFIER (EQUAL ConstExpr)? (COMMA EnumField) COMMA?
    fn enumField(parser: *Parser) !*Node {}

    /// RecordSpecifier <- (Keyword_struct / Keyword_union) IDENTIFIER? (LBRACE RecordField+ RBRACE)?
    fn recordSpecifier(parser: *Parser) !*Node {}

    /// RecordField
    ///     <- TypeSpec* (RecordDeclarator (COMMA RecordDeclarator))? SEMICOLON
    ///     \ StaticAssert
    fn recordField(parser: *Parser) !*Node {}

    /// TypeName
    ///     <- TypeSpec* AbstractDeclarator?
    fn typeName(parser: *Parser) !*Node {

    /// RecordDeclarator <- Declarator? (COLON ConstExpr)?
    fn recordDeclarator(parser: *Parser) !*Node {}

    /// Declarator <- Pointer? DirectDeclarator
    fn declarator(parser: *Parser) !*Node {}

    /// Pointer <- ASTERISK TypeQual* Pointer?
    fn pointer(parser: *Parser) !*Node {}

    /// DirectDeclarator
    ///     <- IDENTIFIER
    ///     / LPAREN Declarator RPAREN
    ///     / DirectDeclarator LBRACKET (ASTERISK / BracketDeclarator)? RBRACKET
    ///     / DirectDeclarator LPAREN (ParamDecl (COMMA ParamDecl)* (COMMA ELLIPSIS)?)? RPAREN
    fn directDeclarator(parser: *Parser) !*Node {}

    /// BracketDeclarator
    ///     <- Keyword_static TypeQual* AssignmentExpr
    ///     / TypeQual+ (ASTERISK / Keyword_static AssignmentExpr)
    ///     / TypeQual+ AssignmentExpr?
    ///     / AssignmentExpr
    fn bracketDeclarator(parser: *Parser) !*Node {}

    /// ParamDecl <- DeclSpec (Declarator / AbstractDeclarator)
    fn paramDecl(parser: *Parser) !*Node {}

    /// AbstractDeclarator <- Pointer? DirectAbstractDeclarator?
    fn abstractDeclarator(parser: *Parser) !*Node {}

    /// DirectAbstractDeclarator
    ///     <- IDENTIFIER
    ///     / LPAREN DirectAbstractDeclarator RPAREN
    ///     / DirectAbstractDeclarator? LBRACKET (ASTERISK / BracketDeclarator)? RBRACKET
    ///     / DirectAbstractDeclarator? LPAREN (ParamDecl (COMMA ParamDecl)* (COMMA ELLIPSIS)?)? RPAREN
    fn directAbstractDeclarator(parser: *Parser) !*Node {}

    /// Expr <- AssignmentExpr (COMMA Expr)*
    fn expr(parser: *Parser) !*Node {}

    /// AssignmentExpr
    ///     <- ConditionalExpr // TODO recursive?
    ///     / UnaryExpr (EQUAL / ASTERISKEQUAL / SLASHEQUAL / PERCENTEQUAL / PLUSEQUAL / MINUSEQUA /
    ///     / ANGLEBRACKETANGLEBRACKETLEFTEQUAL / ANGLEBRACKETANGLEBRACKETRIGHTEQUAL /
    ///     / AMPERSANDEQUAL / CARETEQUAL / PIPEEQUAL) AssignmentExpr
    fn assignmentExpr(parser: *Parser) !*Node {}

    /// ConstExpr <- ConditionalExpr
    /// ConditionalExpr <- LogicalOrExpr (QUESTIONMARK Expr COLON ConditionalExpr)?
    fn conditionalExpr(parser: *Parser) !*Node {}

    /// LogicalOrExpr <- LogicalAndExpr (PIPEPIPE LogicalOrExpr)*
    fn logicalOrExpr(parser: *Parser) !*Node {}

    /// LogicalAndExpr <- BinOrExpr (AMPERSANDAMPERSAND LogicalAndExpr)*
    fn logicalAndExpr(parser: *Parser) !*Node {}

    /// BinOrExpr <- BinXorExpr (PIPE BinOrExpr)*
    fn binOrExpr(parser: *Parser) !*Node {}

    /// BinXorExpr <- BinAndExpr (CARET BinXorExpr)*
    fn binXorExpr(parser: *Parser) !*Node {}

    /// BinAndExpr <- EqualityExpr (AMPERSAND BinAndExpr)*
    fn binAndExpr(parser: *Parser) !*Node {}

    /// EqualityExpr <- ComparisionExpr ((EQUALEQUAL / BANGEQUAL) EqualityExpr)*
    fn equalityExpr(parser: *Parser) !*Node {}

    /// ComparisionExpr <- ShiftExpr (ANGLEBRACKETLEFT / ANGLEBRACKETLEFTEQUAL /ANGLEBRACKETRIGHT / ANGLEBRACKETRIGHTEQUAL) ComparisionExpr)*
    fn comparisionExpr(parser: *Parser) !*Node {}

    /// ShiftExpr <- AdditiveExpr (ANGLEBRACKETANGLEBRACKETLEFT / ANGLEBRACKETANGLEBRACKETRIGHT) ShiftExpr)*
    fn shiftExpr(parser: *Parser) !*Node {}

    /// AdditiveExpr <- MultiplicativeExpr (PLUS / MINUS) AdditiveExpr)*
    fn additiveExpr(parser: *Parser) !*Node {}

    /// MultiplicativeExpr <- UnaryExpr (ASTERISK / SLASH / PERCENT) MultiplicativeExpr)*
    fn multiplicativeExpr(parser: *Parser) !*Node {}

    /// UnaryExpr
    ///     <- LPAREN TypeName RPAREN UnaryExpr
    ///     / Keyword_sizeof LAPERN TypeName RPAREN
    ///     / Keyword_sizeof UnaryExpr
    ///     / Keyword_alignof LAPERN TypeName RPAREN
    ///     / (AMPERSAND / ASTERISK / PLUS / PLUSPLUS / MINUS / MINUSMINUS / TILDE / BANG) UnaryExpr
    ///     / PrimaryExpr PostFixExpr*
    fn unaryExpr(parser: *Parser) !*Node {}

    /// PrimaryExpr
    ///     <- IDENTIFIER
    ///     / INTEGERLITERAL / FLITERAL / STRINGLITERAL / CHARLITERAL
    ///     / LPAREN Expr RPAREN
    ///     / Keyword_generic LPAREN AssignmentExpr (COMMA Generic)+ RPAREN
    fn primaryExpr(parser: *Parser) !*Node {}

    /// Generic
    ///     <- TypeName COLON AssignmentExpr
    ///     / Keyword_default COLON AssignmentExpr
    fn generic(parser: *Parser) !*Node {}

    /// PostFixExpr
    ///     <- LPAREN TypeName RPAREN LBRACE Initializers RBRACE
    ///     / LBRACKET Expr RBRACKET
    ///     / LPAREN (AssignmentExpr (COMMA AssignmentExpr)*)? RPAREN
    ///     / (PERIOD / ARROW) IDENTIFIER
    ///     / (PLUSPLUS / MINUSMINUS)
    fn postFixExpr(parser: *Parser) !*Node {}

    /// Initializers <- ((Designator+ EQUAL)? Initializer COMMA)* (Designator+ EQUAL)? Initializer COMMA?
    fn initializers(parser: *Parser) !*Node {}

    /// Initializer
    ///     <- LBRACE Initializers RBRACE
    ///     / AssignmentExpr
    fn initializer(parser: *Parser) !*Node {}

    /// Designator
    ///     <- LBRACKET Initializers RBRACKET
    ///     / PERIOD IDENTIFIER
    fn designator(parser: *Parser) !*Node {}

    /// CompoundStmt <- LBRACE (Declaration / Stmt)* RBRACE
    fn compoundStmt(parser: *Parser) !?*Node {
        const lbrace = parser.eatToken(.LBrace) orelse return null;
        const node = try parser.arena.create(Node.CompoundStmt);
        node.* = .{
            .lbrace = lbrace,
            .statements = Node.JumpStmt.StmtList.init(parser.arena),
            .rbrace = undefined,
        };
        while (parser.declaration() orelse parser.stmt()) |node|
            try node.statements.push(node);
        node.rbrace = try parser.expectToken(.RBrace);
        return &node.base;
    }

    /// Stmt
    ///     <- CompoundStmt
    ///     / Keyword_if LPAREN Expr RPAREN Stmt (Keyword_ELSE Stmt)?
    ///     / Keyword_switch LPAREN Expr RPAREN Stmt
    ///     / Keyword_while LPAREN Expr RPAREN Stmt
    ///     / Keyword_do statement Keyword_while LPAREN Expr RPAREN SEMICOLON
    ///     / Keyword_for LPAREN (Declaration / ExprStmt) ExprStmt Expr? RPAREN Stmt
    ///     / Keyword_default COLON Stmt
    ///     / Keyword_case ConstExpr COLON Stmt
    ///     / Keyword_goto IDENTIFIER SEMICOLON
    ///     / Keyword_continue SEMICOLON
    ///     / Keyword_break SEMICOLON
    ///     / Keyword_return Expr? SEMICOLON
    ///     / IDENTIFIER COLON Stmt
    ///     / ExprStmt
    fn stmt(parser: *Parser) !?*Node {
        if (parser.compoundStmt()) |node| return node;
        if (parser.eatToken(.Keyword_if)) |tok| {
            const node = try parser.arena.create(Node.IfStmt);
            _ = try parser.expectToken(.LParen);
            node.* = .{
                .@"if" = tok,
                .cond = try parser.expect(expr, .{
                    .ExpectedExpr = .{ .token = it.index },
                }),
                .@"else" = null,
            };
            _ = try parser.expectToken(.RParen);
            if (parser.eatToken(.Keyword_else)) |else_tok| {
                node.@"else" = .{
                    .tok = else_tok,
                    .stmt = try parser.stmt(expr, .{
                        .ExpectedStmt = .{ .token = it.index },
                    }),
                };
            }
            return &node.base;
        }
        // if (parser.eatToken(.Keyword_switch)) |tok| {}
        // if (parser.eatToken(.Keyword_while)) |tok| {}
        // if (parser.eatToken(.Keyword_do)) |tok| {}
        // if (parser.eatToken(.Keyword_for)) |tok| {}
        // if (parser.eatToken(.Keyword_default)) |tok| {}
        // if (parser.eatToken(.Keyword_case)) |tok| {}
        if (parser.eatToken(.Keyword_goto)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .Goto,
                .semicolon = parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_continue)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .Continue,
                .semicolon = parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_break)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .Break,
                .semicolon = parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Keyword_return)) |tok| {
            const node = try parser.arena.create(Node.JumpStmt);
            node.* = .{
                .ltoken = tok,
                .kind = .{ .Return = try parser.expr() },
                .semicolon = parser.expectToken(.Semicolon),
            };
            return &node.base;
        }
        if (parser.eatToken(.Identifier)) |tok| {
            if (parser.eatToken(.Colon)) |col| {
                const node = try parser.arena.create(Node.Label);
                node.* = .{
                    .identifier = tok,
                    .semicolon = parser.expectToken(.Colon),
                };
                return &node.base;
            }
            putBackToken(tok);
        }
        if (parser.exprStmt()) |node| return node;
        return null;
    }

    /// ExprStmt <- Expr? SEMICOLON
    fn exprStmt(parser: *Parser) !*Node {
        const node = try parser.arena.create(Node.ExprStmt);
        node.* = .{
            .expr = try parser.expr(),
            .semicolon = parser.expectToken(.Semicolon),
        };
        return &node.base;
    }

    fn eatToken(parser: *Parser, id: @TagType(Token.Id)) ?TokenIndex {
        while (true) {
            const next_tok = parser.it.next() orelse return null;
            if (next_tok.id != .LineComment and next_tok.id != .MultiLineComment) {
                if (next_tok.id == id) {
                    return parser.it.index;
                }
                _ = parser.it.prev();
                return null;
            }
        }
    }

    fn expectToken(parser: *Parser, id: @TagType(Token.Id)) Error!TokenIndex {
        while (true) {
            const next_tok = parser.it.next() orelse return error.ParseError;
            if (next_tok.id != .LineComment and next_tok.id != .MultiLineComment) {
                if (next_tok.id != id) {
                    try parser.tree.errors.push(.{
                        .ExpectedToken = .{ .token = parser.it.index, .expected_id = id },
                    });
                    return error.ParseError;
                }
                return parser.it.index;
            }
        }
    }

    fn putBackToken(parser: *Parser, putting_back: TokenIndex) void {
        while (true) {
            const prev_tok = parser.it.prev() orelse return;
            if (prev_tok.id == .LineComment or prev_tok.id == .MultiLineComment) continue;
            assert(parser.it.list.at(putting_back) == prev_tok);
            return;
        }
    }

    fn expect(
        parser: *Parser,
        parseFn: fn (*Parser) Error!?*Node,
        err: ast.Error, // if parsing fails
    ) Error!*Node {
        return (try parseFn(parser)) orelse {
            try parser.tree.errors.push(err);
            return error.ParseError;
        };
    }

    fn warning(parser: *Parser, err: ast.Error) Error!void {
        if (parser.tree.warnings) |*w| {
            try w.push(err);
            return;
        }
        try parser.tree.errors.push(err);
        return error.ParseError;
    }
};
