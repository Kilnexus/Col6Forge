const std = @import("std");

pub const nodes = @import("nodes.zig");
pub const print = @import("print.zig");

// Keep this list synchronized with `nodes.zig` so new AST node types are
// available through `ast.mod` without ad-hoc drift.
pub const Program = nodes.Program;
pub const ProgramUnitKind = nodes.ProgramUnitKind;
pub const ProgramUnit = nodes.ProgramUnit;
pub const LexicalOwnerKind = nodes.LexicalOwnerKind;
pub const DeclSource = nodes.DeclSource;
pub const TypeKind = nodes.TypeKind;
pub const Decl = nodes.Decl;
pub const TypeDecl = nodes.TypeDecl;
pub const ProcedureTypeSpec = nodes.ProcedureTypeSpec;
pub const ProcedureInterface = nodes.ProcedureInterface;
pub const ProcedureDecl = nodes.ProcedureDecl;
pub const InterfaceProcedure = nodes.InterfaceProcedure;
pub const DerivedTypeDef = nodes.DerivedTypeDef;
pub const TypeBoundProcedureBinding = nodes.TypeBoundProcedureBinding;
pub const InterfaceBlock = nodes.InterfaceBlock;
pub const DimensionDecl = nodes.DimensionDecl;
pub const ParameterDecl = nodes.ParameterDecl;
pub const ParamAssign = nodes.ParamAssign;
pub const CommonDecl = nodes.CommonDecl;
pub const CommonBlock = nodes.CommonBlock;
pub const EquivalenceDecl = nodes.EquivalenceDecl;
pub const EquivalenceGroup = nodes.EquivalenceGroup;
pub const ImplicitDecl = nodes.ImplicitDecl;
pub const ImplicitRule = nodes.ImplicitRule;
pub const NameListDecl = nodes.NameListDecl;
pub const IntentKind = nodes.IntentKind;
pub const IntentDecl = nodes.IntentDecl;
pub const SaveItem = nodes.SaveItem;
pub const SaveDecl = nodes.SaveDecl;
pub const Declarator = nodes.Declarator;
pub const Stmt = nodes.Stmt;
pub const StmtNode = nodes.StmtNode;
pub const Assignment = nodes.Assignment;
pub const PointerAssignment = nodes.PointerAssignment;
pub const NullifyStmt = nodes.NullifyStmt;
pub const AssociateBinding = nodes.AssociateBinding;
pub const AssociateBlock = nodes.AssociateBlock;
pub const SelectRankClauseKind = nodes.SelectRankClauseKind;
pub const SelectRankClause = nodes.SelectRankClause;
pub const SelectRankInfo = nodes.SelectRankInfo;
pub const SelectTypeClauseKind = nodes.SelectTypeClauseKind;
pub const SelectTypeClause = nodes.SelectTypeClause;
pub const SelectTypeBlock = nodes.SelectTypeBlock;
pub const AssignLabelStmt = nodes.AssignLabelStmt;
pub const UseStmt = nodes.UseStmt;
pub const UseOnlyItem = nodes.UseOnlyItem;
pub const CallStmt = nodes.CallStmt;
pub const ActualArgExpr = nodes.ActualArgExpr;
pub const CallArg = nodes.CallArg;
pub const ReturnStmt = nodes.ReturnStmt;
pub const EntryStmt = nodes.EntryStmt;
pub const WriteStmt = nodes.WriteStmt;
pub const ReadStmt = nodes.ReadStmt;
pub const OpenStmt = nodes.OpenStmt;
pub const InquireStmt = nodes.InquireStmt;
pub const CloseStmt = nodes.CloseStmt;
pub const AllocateTypeSpec = nodes.AllocateTypeSpec;
pub const AllocationOptionKind = nodes.AllocationOptionKind;
pub const AllocationOption = nodes.AllocationOption;
pub const AllocateStmt = nodes.AllocateStmt;
pub const AllocateItem = nodes.AllocateItem;
pub const DeallocateItem = nodes.DeallocateItem;
pub const DeallocateStmt = nodes.DeallocateStmt;
pub const ControlItem = nodes.ControlItem;
pub const RewindStmt = nodes.RewindStmt;
pub const BackspaceStmt = nodes.BackspaceStmt;
pub const EndfileStmt = nodes.EndfileStmt;
pub const DataInit = nodes.DataInit;
pub const DataValueSpec = nodes.DataValueSpec;
pub const DataGroup = nodes.DataGroup;
pub const DataStmt = nodes.DataStmt;
pub const FormatStmt = nodes.FormatStmt;
pub const FormatSpec = nodes.FormatSpec;
pub const BlankControl = nodes.BlankControl;
pub const SignControl = nodes.SignControl;
pub const TabControl = nodes.TabControl;
pub const TabFormat = nodes.TabFormat;
pub const RepeatFormat = nodes.RepeatFormat;
pub const FormatItem = nodes.FormatItem;
pub const IntFormat = nodes.IntFormat;
pub const RealFormat = nodes.RealFormat;
pub const RealFormatKind = nodes.RealFormatKind;
pub const CharFormat = nodes.CharFormat;
pub const LogicalFormat = nodes.LogicalFormat;
pub const IfSingle = nodes.IfSingle;
pub const IfBlock = nodes.IfBlock;
pub const WhereStmt = nodes.WhereStmt;
pub const ArithIfStmt = nodes.ArithIfStmt;
pub const PauseStmt = nodes.PauseStmt;
pub const GotoStmt = nodes.GotoStmt;
pub const ComputedGotoStmt = nodes.ComputedGotoStmt;
pub const AssignedGotoStmt = nodes.AssignedGotoStmt;
pub const DoLoopStmt = nodes.DoLoopStmt;
pub const DoWhileStmt = nodes.DoWhileStmt;
pub const DoInfiniteStmt = nodes.DoInfiniteStmt;
pub const ImpliedDo = nodes.ImpliedDo;
pub const ArrayConstructor = nodes.ArrayConstructor;
pub const ArrayConstructorTypeSpec = nodes.ArrayConstructorTypeSpec;
pub const SourceRef = nodes.SourceRef;
pub const ExprSource = nodes.ExprSource;
pub const Expr = nodes.Expr;
pub const DimRange = nodes.DimRange;
pub const Literal = nodes.Literal;
pub const LiteralKind = nodes.LiteralKind;
pub const CallOrSubscript = nodes.CallOrSubscript;
pub const SubstringExpr = nodes.SubstringExpr;
pub const ComponentExpr = nodes.ComponentExpr;
pub const ComplexLiteral = nodes.ComplexLiteral;
pub const UnaryExpr = nodes.UnaryExpr;
pub const UnaryOp = nodes.UnaryOp;
pub const BinaryExpr = nodes.BinaryExpr;
pub const BinaryOp = nodes.BinaryOp;

pub const printProgram = print.printProgram;

comptime {
    for (std.meta.declarations(nodes)) |decl| {
        if (!@hasDecl(@This(), decl.name)) {
            @compileError(std.fmt.comptimePrint(
                "ast/mod.zig missing re-export for nodes.{s}",
                .{decl.name},
            ));
        }
    }
}
