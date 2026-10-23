using System.Globalization;
using System.Text;

namespace BankFas.Core.Finance;

/// <summary>A node of a parsed formula (BR-FIN-009): the expression is a tree, never executed as text.</summary>
public abstract record FormulaNode;
public sealed record NumberNode(decimal Value) : FormulaNode;
public sealed record RefNode(string Code) : FormulaNode;
public sealed record NegateNode(FormulaNode Operand) : FormulaNode;
public sealed record BinaryNode(char Op, FormulaNode Left, FormulaNode Right) : FormulaNode;
public sealed record CallNode(string Function, IReadOnlyList<FormulaNode> Args) : FormulaNode;

/// <summary>A problem of a formula at save: the position in the text (0-based) and what is wrong.</summary>
public sealed record FormulaError(int Position, string Code, string Message);

/// <summary>The result of parsing: the tree, or the errors; the codes and input kinds the formula reads; its depth (1 without brackets or functions, one more for each level of them).</summary>
public sealed record ParsedFormula(FormulaNode? Tree, IReadOnlyList<FormulaError> Errors, IReadOnlySet<string> Codes, IReadOnlySet<string> InputKinds, int Depth)
{
    public bool IsValid => Errors.Count == 0 && Tree is not null;
}

/// <summary>The value of an input at an offset: 0 is the period tested, k the k-th period before it (PRIOR, SUM, AVG, MIN, MAX).</summary>
public interface IFormulaInputs
{
    decimal? Value(string code, int offset);
}

/// <summary>A value, or why there is none (UNDEFINED is MISSING_DATA with its reason, BR-FIN-009).</summary>
public readonly record struct FormulaValue(decimal? Value, string? Undefined)
{
    public static FormulaValue Of(decimal v) => new(v, null);
    public static FormulaValue None(string why) => new(null, why);
}

/// <summary>
/// The grammar of BR-FIN-009 (spec 12): numbers, the codes of the statement line catalogue, AVG_BAL, MIN_BAL, END_BAL
/// and FLOW_TO_BANK; + − × ÷ (also * and /) and brackets; SUM, AVG, MIN and MAX(x, n) over the last n periods,
/// PRIOR(x, k) the value k periods before, and ABS(x). At save a formula is refused for a character outside the
/// grammar, an unknown code, a depth above 10 or a division by a constant zero; at run a division by zero or a missing
/// input makes it UNDEFINED.
/// </summary>
public static class Formula
{
    public const int MaxDepth = 10;
    public const string AvgBalance = "AVG_BAL", MinBalance = "MIN_BAL", EndBalance = "END_BAL", FlowToBank = "FLOW_TO_BANK";
    public static readonly IReadOnlySet<string> AccountCodes = new HashSet<string>(StringComparer.Ordinal) { AvgBalance, MinBalance, EndBalance };
    private static readonly HashSet<string> Functions = new(StringComparer.Ordinal) { "SUM", "AVG", "MIN", "MAX", "PRIOR", "ABS" };

    /// <summary>The kind of input a code reads.</summary>
    public static string KindOf(string code) => AccountCodes.Contains(code) ? "ACCOUNT_STATS" : code == FlowToBank ? "BANK_FLOWS" : "STATEMENT";

    private enum T { Number, Name, Op, Open, Close, Comma, End }
    private readonly record struct Token(T Kind, string Text, int Pos);

    private static List<Token> Lex(string text, List<FormulaError> errors)
    {
        var tokens = new List<Token>();
        var i = 0;
        while (i < text.Length)
        {
            var ch = text[i];
            if (char.IsWhiteSpace(ch)) { i++; continue; }
            if (ch is >= '0' and <= '9' || (ch == '.' && i + 1 < text.Length && char.IsAsciiDigit(text[i + 1])))
            {
                var start = i;
                while (i < text.Length && (char.IsAsciiDigit(text[i]) || text[i] == '.')) i++;
                tokens.Add(new Token(T.Number, text[start..i], start));
                continue;
            }
            if (ch is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_')
            {
                var start = i;
                while (i < text.Length && (char.IsAsciiLetterOrDigit(text[i]) || text[i] == '_')) i++;
                tokens.Add(new Token(T.Name, text[start..i].ToUpperInvariant(), start));
                continue;
            }
            switch (ch)
            {
                case '+' or '-' or '−': tokens.Add(new Token(T.Op, ch == '−' ? "-" : ch.ToString(), i)); break;
                case '*' or '×': tokens.Add(new Token(T.Op, "*", i)); break;
                case '/' or '÷': tokens.Add(new Token(T.Op, "/", i)); break;
                case '(': tokens.Add(new Token(T.Open, "(", i)); break;
                case ')': tokens.Add(new Token(T.Close, ")", i)); break;
                case ',': tokens.Add(new Token(T.Comma, ",", i)); break;
                default: errors.Add(new FormulaError(i, "CHARACTER", $"The character '{ch}' is not part of a formula.")); break;
            }
            i++;
        }
        tokens.Add(new Token(T.End, "", text.Length));
        return tokens;
    }

    /// <summary>Parses and checks a formula against the known codes (the catalogue's lines and the four account and flow inputs).</summary>
    public static ParsedFormula Parse(string? text, IReadOnlySet<string> knownCodes)
    {
        var errors = new List<FormulaError>();
        var codes = new HashSet<string>(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(text))
            return new ParsedFormula(null, [new FormulaError(0, "EMPTY", "Write the formula.")], codes, new HashSet<string>(), 0);
        if (text.Length > 2000) errors.Add(new FormulaError(2000, "LENGTH", "A formula has at most 2,000 characters."));
        var tokens = Lex(text, errors);
        var p = 0;
        var deepest = 0;
        Token Peek() => tokens[p];
        Token Next() => tokens[p < tokens.Count - 1 ? p++ : p];

        FormulaNode Expr(int depth)
        {
            var left = Term(depth);
            while (Peek().Kind == T.Op && Peek().Text is "+" or "-")
            {
                var op = Next().Text[0];
                left = new BinaryNode(op, left, Term(depth));
            }
            return left;
        }
        FormulaNode Term(int depth)
        {
            var left = Unary(depth);
            while (Peek().Kind == T.Op && Peek().Text is "*" or "/")
            {
                var tok = Next();
                var right = Unary(depth);
                if (tok.Text == "/" && Constant(right) is 0m) errors.Add(new FormulaError(tok.Pos, "DIVIDE_BY_ZERO", "The formula divides by zero."));
                left = new BinaryNode(tok.Text[0], left, right);
            }
            return left;
        }
        FormulaNode Unary(int depth)
        {
            if (Peek().Kind == T.Op && Peek().Text == "-") { Next(); return new NegateNode(Unary(depth)); }
            if (Peek().Kind == T.Op && Peek().Text == "+") { Next(); return Unary(depth); }
            return Primary(depth);
        }
        FormulaNode Primary(int depth)
        {
            var tok = Next();
            deepest = Math.Max(deepest, depth + 1);
            switch (tok.Kind)
            {
                case T.Number:
                    if (!decimal.TryParse(tok.Text, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var n))
                    {
                        errors.Add(new FormulaError(tok.Pos, "NUMBER", $"'{tok.Text}' is not a number."));
                        n = 0;
                    }
                    return new NumberNode(n);
                case T.Name when Peek().Kind == T.Open:
                {
                    Next();
                    if (!Functions.Contains(tok.Text)) errors.Add(new FormulaError(tok.Pos, "FUNCTION", $"{tok.Text} is not a function of a formula (SUM, AVG, MIN, MAX, PRIOR, ABS)."));
                    var args = new List<FormulaNode> { Expr(depth + 1) };
                    while (Peek().Kind == T.Comma) { Next(); args.Add(Expr(depth + 1)); }
                    Expect(T.Close, ")");
                    var expected = tok.Text == "ABS" ? 1 : 2;
                    if (Functions.Contains(tok.Text) && args.Count != expected)
                        errors.Add(new FormulaError(tok.Pos, "ARGUMENTS", tok.Text == "ABS" ? "ABS takes one value." : $"{tok.Text} takes a value and a number of periods."));
                    else if (Functions.Contains(tok.Text) && expected == 2 && (Constant(args[1]) is not { } k || k != decimal.Truncate(k) || k < 1 || k > 60))
                        errors.Add(new FormulaError(tok.Pos, "PERIODS", $"The second value of {tok.Text} is a whole number of periods from 1 to 60."));
                    return new CallNode(tok.Text, args);
                }
                case T.Name:
                    if (!knownCodes.Contains(tok.Text) && !AccountCodes.Contains(tok.Text) && tok.Text != FlowToBank)
                        errors.Add(new FormulaError(tok.Pos, "UNKNOWN_CODE", $"{tok.Text} is not a line of the catalogue nor AVG_BAL, MIN_BAL, END_BAL or FLOW_TO_BANK."));
                    codes.Add(tok.Text);
                    return new RefNode(tok.Text);
                case T.Open:
                {
                    var inner = Expr(depth + 1);
                    Expect(T.Close, ")");
                    return inner;
                }
                default:
                    errors.Add(new FormulaError(tok.Pos, "SYNTAX", tok.Kind == T.End ? "The formula ends too early." : $"'{tok.Text}' is not expected here."));
                    return new NumberNode(0);
            }
        }
        void Expect(T kind, string text)
        {
            if (Peek().Kind == kind) Next();
            else errors.Add(new FormulaError(Peek().Pos, "SYNTAX", $"'{text}' is expected here."));
        }

        FormulaNode? tree = null;
        if (errors.Count == 0)
        {
            tree = Expr(0);
            if (Peek().Kind != T.End) errors.Add(new FormulaError(Peek().Pos, "SYNTAX", $"'{Peek().Text}' is not expected here."));
        }
        var depthOf = deepest;
        if (depthOf > MaxDepth) errors.Add(new FormulaError(0, "DEPTH", $"The formula nests {depthOf} levels; at most {MaxDepth}."));
        var kinds = codes.Select(KindOf).ToHashSet(StringComparer.Ordinal);
        return new ParsedFormula(errors.Count == 0 ? tree : null, errors, codes, kinds, depthOf);
    }

    /// <summary>The value of a subtree that reads no input, else null.</summary>
    public static decimal? Constant(FormulaNode node) => node switch
    {
        NumberNode n => n.Value,
        NegateNode n => -Constant(n.Operand),
        BinaryNode b when Constant(b.Left) is { } l && Constant(b.Right) is { } r => b.Op switch
        {
            '+' => l + r, '-' => l - r, '*' => l * r, '/' => r == 0 ? null : l / r, _ => null,
        },
        CallNode { Function: "ABS" } c when Constant(c.Args[0]) is { } v => Math.Abs(v),
        _ => null,
    };

    /// <summary>Evaluates a tree at the tested period (offset 0); full precision (BR-FIN-011).</summary>
    public static FormulaValue Evaluate(FormulaNode node, IFormulaInputs inputs, int offset = 0)
    {
        switch (node)
        {
            case NumberNode n: return FormulaValue.Of(n.Value);
            case RefNode r:
                return inputs.Value(r.Code, offset) is { } found ? FormulaValue.Of(found)
                    : FormulaValue.None(offset == 0 ? $"{r.Code} has no value" : $"{r.Code} has no value {offset} period(s) before");
            case NegateNode n:
            {
                var v = Evaluate(n.Operand, inputs, offset);
                return v.Value is { } x ? FormulaValue.Of(-x) : v;
            }
            case BinaryNode b:
            {
                var l = Evaluate(b.Left, inputs, offset);
                if (l.Value is not { } lv) return l;
                var r = Evaluate(b.Right, inputs, offset);
                if (r.Value is not { } rv) return r;
                try
                {
                    return b.Op switch
                    {
                        '+' => FormulaValue.Of(lv + rv),
                        '-' => FormulaValue.Of(lv - rv),
                        '*' => FormulaValue.Of(lv * rv),
                        _ => rv == 0 ? FormulaValue.None($"division by zero ({Describe(b.Right)} is 0)") : FormulaValue.Of(lv / rv),
                    };
                }
                catch (OverflowException)
                {
                    return FormulaValue.None("the value is too large");
                }
            }
            case CallNode { Function: "ABS" } c:
            {
                var v = Evaluate(c.Args[0], inputs, offset);
                return v.Value is { } x ? FormulaValue.Of(Math.Abs(x)) : v;
            }
            case CallNode { Function: "PRIOR" } c:
                return Evaluate(c.Args[0], inputs, offset + (int)Constant(c.Args[1])!.Value);
            case CallNode c:
            {
                var periods = (int)Constant(c.Args[1])!.Value;
                var values = new List<decimal>(periods);
                for (var k = 0; k < periods; k++)
                {
                    var v = Evaluate(c.Args[0], inputs, offset + k);
                    if (v.Value is not { } x) return v;
                    values.Add(x);
                }
                return c.Function switch
                {
                    "SUM" => FormulaValue.Of(values.Sum()),
                    "AVG" => FormulaValue.Of(values.Sum() / values.Count),
                    "MIN" => FormulaValue.Of(values.Min()),
                    _ => FormulaValue.Of(values.Max()),
                };
            }
            default: return FormulaValue.None("unknown node");
        }
    }

    /// <summary>The text of a subtree, for the reason of an undefined value.</summary>
    public static string Describe(FormulaNode node)
    {
        var sb = new StringBuilder();
        void Write(FormulaNode n)
        {
            switch (n)
            {
                case NumberNode x: sb.Append(x.Value.ToString(CultureInfo.InvariantCulture)); break;
                case RefNode x: sb.Append(x.Code); break;
                case NegateNode x: sb.Append('-'); Write(x.Operand); break;
                case BinaryNode x: sb.Append('('); Write(x.Left); sb.Append(' ').Append(x.Op).Append(' '); Write(x.Right); sb.Append(')'); break;
                case CallNode x:
                    sb.Append(x.Function).Append('(');
                    for (var i = 0; i < x.Args.Count; i++) { if (i > 0) sb.Append(", "); Write(x.Args[i]); }
                    sb.Append(')');
                    break;
            }
        }
        Write(node);
        return sb.ToString();
    }

    /// <summary>The number of periods back a tree reads (PRIOR, SUM...): 0 for the tested period only.</summary>
    public static int Lookback(FormulaNode node) => node switch
    {
        NegateNode n => Lookback(n.Operand),
        BinaryNode b => Math.Max(Lookback(b.Left), Lookback(b.Right)),
        CallNode { Function: "ABS" } c => Lookback(c.Args[0]),
        CallNode { Function: "PRIOR" } c => (int)(Constant(c.Args[1]) ?? 0) + Lookback(c.Args[0]),
        CallNode c => (int)(Constant(c.Args[1]) ?? 1) - 1 + Lookback(c.Args[0]),
        _ => 0,
    };
}

/// <summary>Inputs from a dictionary of the tested period, and earlier periods by offset.</summary>
public sealed class DictionaryInputs(IReadOnlyDictionary<string, decimal?> current, IReadOnlyList<IReadOnlyDictionary<string, decimal?>>? earlier = null) : IFormulaInputs
{
    public decimal? Value(string code, int offset)
    {
        var map = offset == 0 ? current : earlier is not null && offset - 1 < earlier.Count ? earlier[offset - 1] : null;
        return map is not null && map.TryGetValue(code, out var v) ? v : null;
    }
}
