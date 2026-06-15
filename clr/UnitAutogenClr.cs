// =============================================================================
// UnitAutogen v0.13 - SSMS-native predicate parser (ScriptDom hosted in SQLCLR).
//
// A faithful C# port of powershell/UnitAutogen/Get-ParsedPredicates.ps1. Walks the
// ScriptDom AST of each user procedure, builds the predicate TREE + per-direction
// SEED PLANS, and writes TestGen.PredicateInbox via TestGen.AddParsedPredicate over
// the CLR context connection. The emitted JSON uses the SAME keys/values the
// PowerShell parser produced, so modules 31-34 (seeder/test-gen) are unchanged.
//
// Entry points (registered as T-SQL procs in the installer):
//   EXEC TestGen.ParseDatabasePredicates  @SchemaFilter = N'dbo';  -- or NULL/'*' = all
//   EXEC TestGen.ParseProcedurePredicates @Schema = N'dbo', @ProcName = N'AssessCustomer';
//
// Compile (net472, references the bundled ScriptDom + System.Data):
//   csc /target:library /out:UnitAutogenClr.dll
//       /reference:Microsoft.SqlServer.TransactSql.ScriptDom.dll
//       /reference:System.Data.dll UnitAutogenClr.cs
//
// See design/DESIGN_v0_13_SqlClrParser.md.
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Data.SqlTypes;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.SqlServer.Server;
using SD = Microsoft.SqlServer.TransactSql.ScriptDom;

public static class UnitAutogenClr
{
    public const string ParserSignature = "ParseDatabasePredicates/0.13";

    // ---------------------------------------------------------------------
    // Result holders (mirror the PowerShell @{ ok; reason; ... } hashtables).
    // ---------------------------------------------------------------------
    private sealed class TreeR { public bool ok = true; public string reason; public Dictionary<string, object> node; }
    private sealed class OvR { public bool ok = true; public string reason; public List<object> overrides = new List<object>(); }
    private sealed class DemR { public bool ok = true; public string reason; public List<object> demands = new List<object>(); }
    private sealed class JoinR { public bool ok = true; public string reason; public List<Dictionary<string, object>> tables = new List<Dictionary<string, object>>(); public List<Dictionary<string, object>> steps = new List<Dictionary<string, object>>(); }
    private sealed class FromR { public bool ok = true; public string reason; public List<Dictionary<string, object>> tables = new List<Dictionary<string, object>>(); public List<Dictionary<string, object>> joins = new List<Dictionary<string, object>>(); }
    private sealed class LeafR { public bool ok = true; public string reason; public Dictionary<string, object> conj; }
    private sealed class DnfR { public bool ok = true; public string reason; public List<List<Dictionary<string, object>>> terms = new List<List<Dictionary<string, object>>>(); }
    private sealed class EqR { public bool ok = true; public string reason; public List<Dictionary<string, object>> eqs = new List<Dictionary<string, object>>(); }
    private sealed class PredsR { public bool ok = true; public string reason; public List<Dictionary<string, object>> preds = new List<Dictionary<string, object>>(); }

    private static TreeR TOk(Dictionary<string, object> n) { var r = new TreeR(); r.node = n; return r; }
    private static TreeR TFail(string why) { var r = new TreeR(); r.ok = false; r.reason = why; return r; }

    // Map ScriptDom comparison types to T-SQL operators (same 7 as the PS parser).
    private static readonly Dictionary<string, string> CmpOps = new Dictionary<string, string>
    {
        { "Equals", "=" }, { "NotEqualToBrackets", "<>" }, { "NotEqualToExclamation", "<>" },
        { "LessThan", "<" }, { "GreaterThan", ">" }, { "LessThanOrEqualTo", "<=" }, { "GreaterThanOrEqualTo", ">=" }
    };

    // ---------------------------------------------------------------------
    // Tiny helpers: dictionary/array literals + a hand-rolled JSON writer.
    // ---------------------------------------------------------------------
    private static Dictionary<string, object> M(params object[] kv)
    {
        var d = new Dictionary<string, object>();
        for (int i = 0; i + 1 < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
        return d;
    }

    private static string Json(object o)
    {
        var sb = new StringBuilder();
        WriteJson(o, sb);
        return sb.ToString();
    }

    private static void WriteJson(object o, StringBuilder sb)
    {
        if (o == null) { sb.Append("null"); return; }
        if (o is bool) { sb.Append(((bool)o) ? "true" : "false"); return; }
        if (o is string) { WriteJsonStr((string)o, sb); return; }
        if (o is int || o is long) { sb.Append(Convert.ToInt64(o).ToString(CultureInfo.InvariantCulture)); return; }
        if (o is double || o is float) { sb.Append(Convert.ToDouble(o).ToString("R", CultureInfo.InvariantCulture)); return; }
        var dict = o as IDictionary<string, object>;
        if (dict != null)
        {
            sb.Append('{');
            bool first = true;
            foreach (var kv in dict)
            {
                if (!first) sb.Append(',');
                first = false;
                WriteJsonStr(kv.Key, sb);
                sb.Append(':');
                WriteJson(kv.Value, sb);
            }
            sb.Append('}');
            return;
        }
        var en = o as IEnumerable;
        if (en != null)
        {
            sb.Append('[');
            bool first = true;
            foreach (var item in en)
            {
                if (!first) sb.Append(',');
                first = false;
                WriteJson(item, sb);
            }
            sb.Append(']');
            return;
        }
        // Fallback: stringify.
        WriteJsonStr(o.ToString(), sb);
    }

    private static void WriteJsonStr(string s, StringBuilder sb)
    {
        sb.Append('"');
        foreach (char c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ') sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    // ---------------------------------------------------------------------
    // Reflection-based AST child walk (mirrors Get-FragmentChildProps).
    // ---------------------------------------------------------------------
    private static readonly Dictionary<Type, PropertyInfo[]> PropCache = new Dictionary<Type, PropertyInfo[]>();

    private static PropertyInfo[] ChildProps(object node)
    {
        Type t = node.GetType();
        PropertyInfo[] cached;
        lock (PropCache) { if (PropCache.TryGetValue(t, out cached)) return cached; }
        Type fragT = typeof(SD.TSqlFragment);
        Type enT = typeof(IEnumerable);
        var list = t.GetProperties()
            .Where(pi => pi.Name != "ScriptTokenStream"
                         && pi.GetIndexParameters().Length == 0
                         && (fragT.IsAssignableFrom(pi.PropertyType)
                             || (enT.IsAssignableFrom(pi.PropertyType) && pi.PropertyType != typeof(string))))
            .ToArray();
        lock (PropCache) { PropCache[t] = list; }
        return list;
    }

    private static string FragText(SD.TSqlFragment f)
    {
        if (f == null) return "";
        var ts = f.ScriptTokenStream;
        if (ts == null) return "";
        var sb = new StringBuilder();
        for (int i = f.FirstTokenIndex; i <= f.LastTokenIndex; i++) sb.Append(ts[i].Text);
        return sb.ToString().Trim();
    }

    private static string LiteralText(SD.ScalarExpression expr)
    {
        while (expr is SD.ParenthesisExpression) expr = ((SD.ParenthesisExpression)expr).Expression;
        var sl = expr as SD.StringLiteral;
        if (sl != null) return "N'" + sl.Value.Replace("'", "''") + "'";
        if (expr is SD.IntegerLiteral || expr is SD.NumericLiteral || expr is SD.RealLiteral || expr is SD.MoneyLiteral)
            return ((SD.Literal)expr).Value;
        var ue = expr as SD.UnaryExpression;
        if (ue != null && ue.Expression is SD.Literal)
        {
            string sign = (ue.UnaryExpressionType == SD.UnaryExpressionType.Negative) ? "-" : "";
            return sign + ((SD.Literal)ue.Expression).Value;
        }
        return null;
    }

    // ---------------------------------------------------------------------
    // v0.12: body-DML WHERE -> seed overrides. For a gate whose guarded branch
    // is an UPDATE/DELETE with a WHERE of AND-chained "col = <literal>" and
    // "col IN (<literals>)" conjuncts, lift those into seed overrides so the
    // boundary test pre-seeds rows the DML will actually hit (otherwise generic
    // sample rows don't match the filter and a loosened-operator mutation is
    // missed). Conservative: anything not a literal-equality/IN is ignored, and
    // an empty set yields null (-> generic seed; never an error, never a false
    // failure). Returns {"schema","table","overrides":[{"col","val"}]} or null.
    // ---------------------------------------------------------------------
    private static SD.TSqlStatement FirstDmlStatement(SD.TSqlStatement s)
    {
        if (s == null) return null;
        if (s is SD.UpdateStatement || s is SD.DeleteStatement) return s;
        var blk = s as SD.BeginEndBlockStatement;
        if (blk != null && blk.StatementList != null)
            foreach (SD.TSqlStatement c in blk.StatementList.Statements)
            { var d = FirstDmlStatement(c); if (d != null) return d; }
        return null;
    }

    private static string ColName(SD.ColumnReferenceExpression c)
    {
        if (c == null || c.MultiPartIdentifier == null) return null;
        var ids = c.MultiPartIdentifier.Identifiers;
        return ids.Count > 0 ? ids[ids.Count - 1].Value : null;
    }

    private static void CollectEqOverrides(SD.BooleanExpression be, List<object> ov)
    {
        if (be == null) return;
        var bp = be as SD.BooleanParenthesisExpression;
        if (bp != null) { CollectEqOverrides(bp.Expression, ov); return; }
        var bb = be as SD.BooleanBinaryExpression;
        if (bb != null)
        {
            if (bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And)
            { CollectEqOverrides(bb.FirstExpression, ov); CollectEqOverrides(bb.SecondExpression, ov); }
            return; // OR -> cannot guarantee a single seeded row hits both arms; skip
        }
        var bc = be as SD.BooleanComparisonExpression;
        if (bc != null && bc.ComparisonType == SD.BooleanComparisonType.Equals)
        {
            var col = bc.FirstExpression as SD.ColumnReferenceExpression;
            string lit = (col != null) ? LiteralText(bc.SecondExpression) : null;
            if (col == null) { col = bc.SecondExpression as SD.ColumnReferenceExpression; lit = (col != null) ? LiteralText(bc.FirstExpression) : null; }
            string cn = ColName(col);
            if (cn != null && lit != null) ov.Add(M("col", cn, "val", lit));
            return;
        }
        var ip = be as SD.InPredicate;
        if (ip != null && !ip.NotDefined && ip.Subquery == null && ip.Values != null && ip.Values.Count > 0)
        {
            var col = ip.Expression as SD.ColumnReferenceExpression;
            string cn = ColName(col);
            string lit = LiteralText(ip.Values[0]);
            if (cn != null && lit != null) ov.Add(M("col", cn, "val", lit));
            return;
        }
        // anything else (ranges, functions, subqueries, col=col) -> no override
    }

    private static string BodyDmlSeedJsonFor(SD.TSqlStatement thenStmt)
    {
        var stmt = FirstDmlStatement(thenStmt);
        if (stmt == null) return null;
        SD.SchemaObjectName tgt = null; SD.WhereClause where = null;
        var upd = stmt as SD.UpdateStatement;
        if (upd != null && upd.UpdateSpecification != null)
        {
            var t = upd.UpdateSpecification.Target as SD.NamedTableReference;
            if (t != null) tgt = t.SchemaObject;
            where = upd.UpdateSpecification.WhereClause;
        }
        var del = stmt as SD.DeleteStatement;
        if (del != null && del.DeleteSpecification != null)
        {
            var t = del.DeleteSpecification.Target as SD.NamedTableReference;
            if (t != null) tgt = t.SchemaObject;
            where = del.DeleteSpecification.WhereClause;
        }
        if (tgt == null || where == null || where.SearchCondition == null) return null;
        var ov = new List<object>();
        CollectEqOverrides(where.SearchCondition, ov);
        if (ov.Count == 0) return null;
        var parts = tgt.Identifiers.Select(id => id.Value).ToList();
        string tbl = parts[parts.Count - 1];
        string sch = parts.Count >= 2 ? parts[parts.Count - 2] : "dbo";
        return Json(M("schema", sch, "table", tbl, "overrides", ov));
    }

    private static string QuoteIdent(string x)
    {
        if (x == null) return null;
        return "[" + x.Replace("]", "]]") + "]";
    }

    // Single NamedTableReference -> { schema; table; alias; raw }. null otherwise.
    private static Dictionary<string, object> TableRefInfo(SD.TableReference tableRef)
    {
        var nt = tableRef as SD.NamedTableReference;
        if (nt == null) return null;
        var parts = nt.SchemaObject.Identifiers.Select(id => id.Value).ToList();
        string tbl = parts[parts.Count - 1];
        string sch = parts.Count >= 2 ? parts[parts.Count - 2] : "dbo"; // unqualified -> dbo
        string alias = nt.Alias != null ? nt.Alias.Value : null;
        return M("schema", sch, "table", tbl, "alias", alias, "raw", FragText(nt));
    }

    private static bool LitCompare(string l, string opName, string r)
    {
        double lv, rv;
        if (double.TryParse(l, NumberStyles.Any, CultureInfo.InvariantCulture, out lv)
            && double.TryParse(r, NumberStyles.Any, CultureInfo.InvariantCulture, out rv))
        {
            switch (opName)
            {
                case "Equals": return lv == rv;
                case "NotEqualToBrackets": return lv != rv;
                case "NotEqualToExclamation": return lv != rv;
                case "LessThan": return lv < rv;
                case "GreaterThan": return lv > rv;
                case "LessThanOrEqualTo": return lv <= rv;
                case "GreaterThanOrEqualTo": return lv >= rv;
            }
        }
        string ls = Regex.Replace(Regex.Replace(l, "^N?'", ""), "'$", "");
        string rs = Regex.Replace(Regex.Replace(r, "^N?'", ""), "'$", "");
        switch (opName)
        {
            case "Equals": return string.Equals(ls, rs, StringComparison.Ordinal);
            case "NotEqualToBrackets": return !string.Equals(ls, rs, StringComparison.Ordinal);
            case "NotEqualToExclamation": return !string.Equals(ls, rs, StringComparison.Ordinal);
        }
        return false;
    }

    // ScalarSubquery wrapping a single aggregate or single column.
    private static Dictionary<string, object> AggregateInfo(SD.ScalarExpression scalarExpr)
    {
        while (scalarExpr is SD.ParenthesisExpression) scalarExpr = ((SD.ParenthesisExpression)scalarExpr).Expression;
        var ss = scalarExpr as SD.ScalarSubquery;
        if (ss == null) return null;
        var qe = ss.QueryExpression as SD.QuerySpecification;
        if (qe == null) return null;
        if (qe.SelectElements.Count != 1) return null;
        var sel = qe.SelectElements[0] as SD.SelectScalarExpression;
        if (sel == null) return null;
        var inner = sel.Expression;
        var fc = inner as SD.FunctionCall;
        if (fc != null)
        {
            string agg = fc.FunctionName.Value.ToUpperInvariant();
            if (agg == "COUNT" || agg == "SUM" || agg == "MIN" || agg == "MAX" || agg == "AVG")
                return M("Aggregate", agg, "ColumnText", FragText(fc), "QuerySpec", qe);
            return null;
        }
        if (inner is SD.ColumnReferenceExpression)
            return M("Aggregate", "SCALAR", "ColumnText", FragText(inner), "QuerySpec", qe);
        return null;
    }

    // ---------------------------------------------------------------------
    // Join capture (general join tree: inner/outer/non-equi, left-deep).
    // ---------------------------------------------------------------------
    private static PredsR JoinPredicates(SD.BooleanExpression onExpr)
    {
        var outR = new PredsR();
        if (onExpr == null) { outR.ok = false; outR.reason = "join has no ON condition"; return outR; }
        var stack = new Stack<SD.BooleanExpression>();
        stack.Push(onExpr);
        while (stack.Count > 0)
        {
            var n = stack.Pop();
            var bp = n as SD.BooleanParenthesisExpression;
            if (bp != null) { stack.Push(bp.Expression); continue; }
            var bb = n as SD.BooleanBinaryExpression;
            if (bb != null)
            {
                if (bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And) { stack.Push(bb.FirstExpression); stack.Push(bb.SecondExpression); continue; }
                outR.ok = false; outR.reason = "join ON uses OR composition"; return outR;
            }
            var bc = n as SD.BooleanComparisonExpression;
            if (bc != null)
            {
                string op;
                if (!CmpOps.TryGetValue(bc.ComparisonType.ToString(), out op)) { outR.ok = false; outR.reason = "join ON has an unsupported comparator"; return outR; }
                var l = bc.FirstExpression as SD.ColumnReferenceExpression;
                var r = bc.SecondExpression as SD.ColumnReferenceExpression;
                if (l != null && r != null)
                {
                    var li = l.MultiPartIdentifier.Identifiers; var ri = r.MultiPartIdentifier.Identifiers;
                    string la = li.Count >= 2 ? li[li.Count - 2].Value : null;
                    string ra = ri.Count >= 2 ? ri[ri.Count - 2].Value : null;
                    outR.preds.Add(M("lAlias", la, "lCol", li[li.Count - 1].Value, "op", op, "rAlias", ra, "rCol", ri[ri.Count - 1].Value));
                    continue;
                }
                outR.ok = false; outR.reason = "join ON is not column <op> column"; return outR;
            }
            outR.ok = false; outR.reason = "join ON is not a comparison (or AND of comparisons)"; return outR;
        }
        return outR;
    }

    private static JoinR CollectJoinTree(SD.TableReference reference)
    {
        var nt = reference as SD.NamedTableReference;
        if (nt != null)
        {
            var info = TableRefInfo(reference);
            if (info == null) { var f = new JoinR(); f.ok = false; f.reason = "FROM table is not a plain named table"; return f; }
            var ok = new JoinR(); ok.tables.Add(info); return ok;
        }
        var qj = reference as SD.QualifiedJoin;
        if (qj != null)
        {
            string type;
            switch (qj.QualifiedJoinType)
            {
                case SD.QualifiedJoinType.Inner: type = "INNER"; break;
                case SD.QualifiedJoinType.LeftOuter: type = "LEFT"; break;
                case SD.QualifiedJoinType.RightOuter: type = "RIGHT"; break;
                case SD.QualifiedJoinType.FullOuter: type = "FULL"; break;
                default: { var f = new JoinR(); f.ok = false; f.reason = "join type " + qj.QualifiedJoinType + " not supported"; return f; }
            }
            var left = CollectJoinTree(qj.FirstTableReference); if (!left.ok) return left;
            var right = CollectJoinTree(qj.SecondTableReference); if (!right.ok) return right;
            if (right.tables.Count != 1 || right.steps.Count > 0) { var f = new JoinR(); f.ok = false; f.reason = "only left-deep join chains are supported (right-nested join)"; return f; }
            var on = JoinPredicates(qj.SearchCondition); if (!on.ok) { var f = new JoinR(); f.ok = false; f.reason = on.reason; return f; }
            string addAlias = right.tables[0]["alias"] != null ? (string)right.tables[0]["alias"] : (string)right.tables[0]["table"];
            var step = M("type", type, "addAlias", addAlias, "on", on.preds.Cast<object>().ToList());
            var res = new JoinR();
            res.tables.AddRange(left.tables); res.tables.AddRange(right.tables);
            res.steps.AddRange(left.steps); res.steps.Add(step);
            return res;
        }
        var fail = new JoinR(); fail.ok = false; fail.reason = "FROM is a derived table / TVF / APPLY (not a plain table or join)"; return fail;
    }

    // ---------------------------------------------------------------------
    // WHERE -> single comparison leaf { col; op; val; valKind; tbl }.
    // ---------------------------------------------------------------------
    private static LeafR WhereLeaf(SD.BooleanExpression n)
    {
        var bc = n as SD.BooleanComparisonExpression;
        if (bc == null)
            return new LeafR { ok = false, reason = "WHERE contains an unsupported predicate construct (only column op literal/@param comparisons, AND/OR composed)" };
        string op;
        if (!CmpOps.TryGetValue(bc.ComparisonType.ToString(), out op))
            return new LeafR { ok = false, reason = "WHERE comparator " + bc.ComparisonType + " not supported" };
        string col = null, val = null, valKind = null, colTbl = null;
        string col2 = null, col2Tbl = null;   // v0.14.2: second column for column-to-column
        foreach (var side in new SD.ScalarExpression[] { bc.FirstExpression, bc.SecondExpression })
        {
            var cr = side as SD.ColumnReferenceExpression;
            if (cr != null)
            {
                var cids = cr.MultiPartIdentifier.Identifiers;
                string cn = cids[cids.Count - 1].Value;
                string ct = cids.Count >= 2 ? cids[cids.Count - 2].Value : null;
                if (col == null) { col = cn; colTbl = ct; } else { col2 = cn; col2Tbl = ct; }
                continue;
            }
            var vr = side as SD.VariableReference;
            if (vr != null) { val = vr.Name; valKind = "param"; continue; }
            string maybe = LiteralText(side);
            if (maybe != null) { val = maybe; valKind = "literal"; }
        }
        // v0.14.2: column-to-column comparison (a.x <op> b.y), same- or cross-table.
        // FirstExpression is the left column, so the op direction is preserved.
        if (col != null && col2 != null)
            return new LeafR { conj = M("kind", "colcol", "lCol", col, "lTbl", colTbl, "op", op, "rCol", col2, "rTbl", col2Tbl) };
        if (col == null || val == null)
            return new LeafR { ok = false, reason = "WHERE conjunct is not <column> <op> <literal|@param|column> (an expression)" };
        return new LeafR { conj = M("col", col, "op", op, "val", val, "valKind", valKind, "tbl", colTbl) };
    }

    // WHERE -> tree of colpred leaves (and/or/not). node==null => no WHERE.
    private static TreeR BuildWhereTree(SD.BooleanExpression boolExpr)
    {
        if (boolExpr == null) return TOk(null);
        var n = boolExpr;
        var bp = n as SD.BooleanParenthesisExpression;
        if (bp != null) return BuildWhereTree(bp.Expression);
        var bb = n as SD.BooleanBinaryExpression;
        if (bb != null)
        {
            string k = bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And ? "and"
                     : bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.Or ? "or" : null;
            if (k == null) return TFail("WHERE uses unsupported boolean operator " + bb.BinaryExpressionType);
            var L = BuildWhereTree(bb.FirstExpression); if (!L.ok) return L;
            var R = BuildWhereTree(bb.SecondExpression); if (!R.ok) return R;
            var items = new List<object>();
            foreach (var c in new[] { L.node, R.node })
            {
                if (c == null) continue;
                if ((string)c["k"] == k) items.AddRange((List<object>)c["items"]);
                else items.Add(c);
            }
            return TOk(M("k", k, "items", items));
        }
        var bn = n as SD.BooleanNotExpression;
        if (bn != null)
        {
            var i = BuildWhereTree(bn.Expression); if (!i.ok) return i;
            return TOk(M("k", "not", "item", i.node));
        }
        var leaf = WhereLeaf(n);
        if (!leaf.ok) return TFail(leaf.reason);
        var cj = leaf.conj;
        if (cj.ContainsKey("kind") && (string)cj["kind"] == "colcol")
            return TOk(M("k", "colcol", "lTbl", cj["lTbl"], "lCol", cj["lCol"], "op", cj["op"], "rTbl", cj["rTbl"], "rCol", cj["rCol"]));
        return TOk(M("k", "colpred", "tbl", cj["tbl"], "col", cj["col"], "op", cj["op"], "val", cj["val"], "valKind", cj["valKind"]));
    }

    private static TreeR BuildQueryNode(SD.QuerySpecification querySpec)
    {
        if (querySpec.FromClause == null) return TFail("subquery has no FROM clause");
        var refs = querySpec.FromClause.TableReferences;
        if (refs.Count != 1) return TFail("comma-separated FROM (old-style join) not supported");
        var cj = CollectJoinTree(refs[0]); if (!cj.ok) return TFail(cj.reason);
        var whereExpr = querySpec.WhereClause != null ? querySpec.WhereClause.SearchCondition : null;
        var wt = BuildWhereTree(whereExpr); if (!wt.ok) return TFail(wt.reason);
        var tables = cj.tables.Select(t => M("schema", t["schema"], "table", t["table"], "alias", t["alias"])).Cast<object>().ToList();
        var joins = cj.steps.Select(s => M("type", s["type"], "addAlias", s["addAlias"], "on", s["on"])).Cast<object>().ToList();
        return TOk(M("k", "query", "tables", tables, "joins", joins, "where", wt.node));
    }

    // One non-boolean data-shape predicate -> atom node.
    private static TreeR BuildAtomNode(SD.BooleanExpression p)
    {
        var ep = p as SD.ExistsPredicate;
        if (ep != null)
        {
            var qe = ep.Subquery.QueryExpression as SD.QuerySpecification;
            if (qe == null) return TFail("EXISTS subquery is not a simple query spec");
            var q = BuildQueryNode(qe); if (!q.ok) return q;
            return TOk(M("k", "atom", "agg", "EXISTS", "selectExpr", "1", "op", "exists", "comparand", null, "source", q.node));
        }
        var bc = p as SD.BooleanComparisonExpression;
        if (bc != null)
        {
            string op; CmpOps.TryGetValue(bc.ComparisonType.ToString(), out op);
            string lLit = LiteralText(bc.FirstExpression);
            string rLit = LiteralText(bc.SecondExpression);
            if (lLit != null && rLit != null)
                return TOk(M("k", "const", "val", LitCompare(lLit, bc.ComparisonType.ToString(), rLit)));
            var info = AggregateInfo(bc.FirstExpression); SD.ScalarExpression cmpExpr = bc.SecondExpression;
            if (info == null) { info = AggregateInfo(bc.SecondExpression); cmpExpr = bc.FirstExpression; }
            if (info == null) return TFail("comparison does not involve an aggregate/scalar subquery");
            if (op == null) return TFail("unsupported comparison operator");
            string lit = LiteralText(cmpExpr);
            if (lit == null)
            {
                var vr = cmpExpr as SD.VariableReference;
                if (vr != null) lit = vr.Name;
                else return TFail("comparand is not a literal or @parameter");
            }
            var q = BuildQueryNode((SD.QuerySpecification)info["QuerySpec"]); if (!q.ok) return q;
            return TOk(M("k", "atom", "agg", info["Aggregate"], "selectExpr", info["ColumnText"], "op", op, "comparand", lit, "source", q.node));
        }
        var ip = p as SD.InPredicate;
        if (ip != null)
        {
            var info = AggregateInfo(ip.Expression);
            if (info == null || (string)info["Aggregate"] != "COUNT") return TFail("IN not over COUNT(...)");
            if (ip.Subquery != null) return TFail("IN (subquery) not supported");
            var vals = ip.Values.Select(v => LiteralText(v)).ToList();
            if (vals.Contains(null)) return TFail("IN list has a non-literal value");
            var q = BuildQueryNode((SD.QuerySpecification)info["QuerySpec"]); if (!q.ok) return q;
            string op = ip.NotDefined ? "notin" : "in";
            return TOk(M("k", "atom", "agg", "COUNT", "selectExpr", info["ColumnText"], "op", op, "comparand", vals.Cast<object>().ToList(), "source", q.node));
        }
        var te = p as SD.BooleanTernaryExpression;
        if (te != null && te.TernaryExpressionType.ToString().StartsWith("Between"))
        {
            var info = AggregateInfo(te.FirstExpression);
            if (info == null || (string)info["Aggregate"] != "COUNT") return TFail("BETWEEN not over COUNT(...)");
            string a = LiteralText(te.SecondExpression), b = LiteralText(te.ThirdExpression);
            if (a == null || b == null) return TFail("BETWEEN bounds are not literals");
            var q = BuildQueryNode((SD.QuerySpecification)info["QuerySpec"]); if (!q.ok) return q;
            return TOk(M("k", "atom", "agg", "COUNT", "selectExpr", info["ColumnText"], "op", "between", "comparand", new List<object> { a, b }, "source", q.node));
        }
        var inn = p as SD.BooleanIsNullExpression;
        if (inn != null)
        {
            var info = AggregateInfo(inn.Expression);
            if (info == null || (string)info["Aggregate"] != "SCALAR") return TFail("IS NULL not over a scalar subquery");
            var q = BuildQueryNode((SD.QuerySpecification)info["QuerySpec"]); if (!q.ok) return q;
            string op = inn.IsNot ? "isnotnull" : "isnull";
            return TOk(M("k", "atom", "agg", "SCALAR", "selectExpr", info["ColumnText"], "op", op, "comparand", null, "source", q.node));
        }
        return TFail("predicate shape not in the grammar");
    }

    private static List<Dictionary<string, object>> CollectTreeTables(Dictionary<string, object> node)
    {
        var acc = new List<Dictionary<string, object>>();
        if (node == null) return acc;
        string k = (string)node["k"];
        if (k == "atom")
        {
            var src = (Dictionary<string, object>)node["source"];
            foreach (var t in (List<object>)src["tables"])
            {
                var td = (Dictionary<string, object>)t;
                acc.Add(M("schema", td["schema"], "table", td["table"], "alias", td["alias"]));
            }
            return acc;
        }
        if (k == "not") return CollectTreeTables((Dictionary<string, object>)node["item"]);
        if (k == "and" || k == "or")
            foreach (var c in (List<object>)node["items"]) acc.AddRange(CollectTreeTables((Dictionary<string, object>)c));
        return acc;
    }

    private static TreeR BuildPredTree(SD.BooleanExpression predicate)
    {
        var n = predicate;
        var bp = n as SD.BooleanParenthesisExpression;
        if (bp != null) return BuildPredTree(bp.Expression);
        var bn = n as SD.BooleanNotExpression;
        if (bn != null)
        {
            var i = BuildPredTree(bn.Expression); if (!i.ok) return i;
            return TOk(M("k", "not", "item", i.node));
        }
        var bb = n as SD.BooleanBinaryExpression;
        if (bb != null)
        {
            string k = bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And ? "and"
                     : bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.Or ? "or" : null;
            if (k == null) return TFail("predicate uses unsupported boolean operator " + bb.BinaryExpressionType);
            var L = BuildPredTree(bb.FirstExpression); if (!L.ok) return L;
            var R = BuildPredTree(bb.SecondExpression); if (!R.ok) return R;
            var items = new List<object>();
            foreach (var c in new[] { L.node, R.node })
            {
                if (c == null) continue;
                if ((string)c["k"] == k) items.AddRange((List<object>)c["items"]);
                else items.Add(c);
            }
            return TOk(M("k", k, "items", items));
        }
        return BuildAtomNode(n);
    }

    // ---------------------------------------------------------------------
    // Render a tree back to SQL (for the strong assertion).
    // ---------------------------------------------------------------------
    private static string RenderWhereNode(Dictionary<string, object> node)
    {
        if (node == null) return null;
        string k = (string)node["k"];
        if (k == "and") return "(" + string.Join(" AND ", ((List<object>)node["items"]).Select(x => RenderWhereNode((Dictionary<string, object>)x))) + ")";
        if (k == "or") return "(" + string.Join(" OR ", ((List<object>)node["items"]).Select(x => RenderWhereNode((Dictionary<string, object>)x))) + ")";
        if (k == "not") return "NOT (" + RenderWhereNode((Dictionary<string, object>)node["item"]) + ")";
        if (k == "colcol")
        {
            string lc2 = node["lTbl"] != null ? QuoteIdent((string)node["lTbl"]) + "." + QuoteIdent((string)node["lCol"]) : QuoteIdent((string)node["lCol"]);
            string rc2 = node["rTbl"] != null ? QuoteIdent((string)node["rTbl"]) + "." + QuoteIdent((string)node["rCol"]) : QuoteIdent((string)node["rCol"]);
            return lc2 + " " + node["op"] + " " + rc2;
        }
        string c = node["tbl"] != null ? QuoteIdent((string)node["tbl"]) + "." + QuoteIdent((string)node["col"]) : QuoteIdent((string)node["col"]);
        return c + " " + node["op"] + " " + node["val"];
    }

    private static string RenderQueryNode(Dictionary<string, object> node)
    {
        var tables = (List<object>)node["tables"];
        var joins = (List<object>)node["joins"];
        var t0 = (Dictionary<string, object>)tables[0];
        string from = QuoteIdent((string)t0["schema"]) + "." + QuoteIdent((string)t0["table"]);
        if (t0["alias"] != null) from += " " + QuoteIdent((string)t0["alias"]);
        for (int i = 0; i < joins.Count; i++)
        {
            var st = (Dictionary<string, object>)joins[i];
            var tb = (Dictionary<string, object>)tables[i + 1];
            var on = string.Join(" AND ", ((List<object>)st["on"]).Select(o =>
            {
                var pd = (Dictionary<string, object>)o;
                return QuoteIdent((string)pd["lAlias"]) + "." + QuoteIdent((string)pd["lCol"]) + " " + pd["op"] + " " + QuoteIdent((string)pd["rAlias"]) + "." + QuoteIdent((string)pd["rCol"]);
            }));
            from += " " + st["type"] + " JOIN " + QuoteIdent((string)tb["schema"]) + "." + QuoteIdent((string)tb["table"]);
            if (tb["alias"] != null) from += " " + QuoteIdent((string)tb["alias"]);
            from += " ON " + on;
        }
        string w = RenderWhereNode((Dictionary<string, object>)node["where"]);
        if (w != null) from += " WHERE " + w;
        return from;
    }

    private static string RenderPredNode(Dictionary<string, object> node)
    {
        string k = (string)node["k"];
        if (k == "const") return ((bool)node["val"]) ? "(1 = 1)" : "(1 = 0)";
        if (k == "and") return "(" + string.Join(" AND ", ((List<object>)node["items"]).Select(x => RenderPredNode((Dictionary<string, object>)x))) + ")";
        if (k == "or") return "(" + string.Join(" OR ", ((List<object>)node["items"]).Select(x => RenderPredNode((Dictionary<string, object>)x))) + ")";
        if (k == "not") return "NOT (" + RenderPredNode((Dictionary<string, object>)node["item"]) + ")";
        string src = RenderQueryNode((Dictionary<string, object>)node["source"]);
        string selectExpr = (string)node["selectExpr"];
        string op = (string)node["op"];
        var comparand = node["comparand"];
        switch (op)
        {
            case "exists": return "EXISTS (SELECT 1 FROM " + src + ")";
            case "isnull": return "(SELECT " + selectExpr + " FROM " + src + ") IS NULL";
            case "isnotnull": return "(SELECT " + selectExpr + " FROM " + src + ") IS NOT NULL";
            case "in": return "(SELECT " + selectExpr + " FROM " + src + ") IN (" + string.Join(", ", ((List<object>)comparand).Select(o => o.ToString())) + ")";
            case "notin": return "(SELECT " + selectExpr + " FROM " + src + ") NOT IN (" + string.Join(", ", ((List<object>)comparand).Select(o => o.ToString())) + ")";
            case "between": { var cl = (List<object>)comparand; return "(SELECT " + selectExpr + " FROM " + src + ") BETWEEN " + cl[0] + " AND " + cl[1]; }
            default: return "(SELECT " + selectExpr + " FROM " + src + ") " + op + " " + comparand;
        }
    }

    // ---------------------------------------------------------------------
    // Truth-propagation -> per-table seed plan (one per direction).
    // ---------------------------------------------------------------------
    private static Dictionary<string, object> ExtractInnerColRef(string selectExpr)
    {
        string s = selectExpr ?? "";
        int op = s.IndexOf('(');
        if (op >= 0) { int cp = s.LastIndexOf(')'); if (cp > op) s = s.Substring(op + 1, cp - op - 1); }
        s = s.Trim().Replace("[", "").Replace("]", "");
        string alias = null;
        if (s.Contains("."))
        {
            alias = s.Substring(0, s.IndexOf('.'));
            s = s.Substring(s.LastIndexOf('.') + 1);
        }
        return M("alias", alias, "col", s);
    }

    private static OvR DriveWhere(Dictionary<string, object> node, bool want, Dictionary<string, string[]> aliasMap)
    {
        var res = new OvR();
        if (node == null) return res;
        string k = (string)node["k"];
        if (k == "colpred")
        {
            var vs = M("satisfy", M("op", node["op"], "val", node["val"], "valKind", node["valKind"], "want", want ? 1 : 0));
            res.overrides.Add(M("tbl", node["tbl"], "col", node["col"], "vspec", vs));
            return res;
        }
        if (k == "colcol")
        {
            // v0.14.2 column-to-column (a.x <op> b.y), same- or cross-table. The right
            // column gets a typed sample S; the left column gets a value satisfying (or,
            // for want=0, violating) <op> against S. Both anchor on S, so the relation
            // holds regardless of the two columns' types.
            string rAlias = (string)node["rTbl"];
            string[] rt = (rAlias != null && aliasMap.ContainsKey(rAlias)) ? aliasMap[rAlias]
                        : (aliasMap.Count == 1 ? aliasMap.Values.First() : null);
            if (rt == null) return new OvR { ok = false, reason = "column-to-column WHERE: cannot resolve the right-hand column's table" };
            res.overrides.Add(M("tbl", node["rTbl"], "col", node["rCol"], "vspec", M("sample", true)));
            res.overrides.Add(M("tbl", node["lTbl"], "col", node["lCol"], "vspec",
                M("satisfyother", M("op", node["op"], "want", want ? 1 : 0, "oschema", rt[0], "otable", rt[1], "ocol", node["rCol"]))));
            return res;
        }
        if (k == "not") return DriveWhere((Dictionary<string, object>)node["item"], !want, aliasMap);
        if (k == "and")
        {
            if (want)
            {
                foreach (var c in (List<object>)node["items"]) { var r = DriveWhere((Dictionary<string, object>)c, true, aliasMap); if (!r.ok) return r; res.overrides.AddRange(r.overrides); }
                return res;
            }
            foreach (var c in (List<object>)node["items"]) { var r = DriveWhere((Dictionary<string, object>)c, false, aliasMap); if (r.ok) return r; }
            return new OvR { ok = false, reason = "cannot violate AND in WHERE" };
        }
        if (k == "or")
        {
            if (want)
            {
                foreach (var c in (List<object>)node["items"]) { var r = DriveWhere((Dictionary<string, object>)c, true, aliasMap); if (r.ok) return r; }
                return new OvR { ok = false, reason = "no WHERE OR disjunct is seedable" };
            }
            foreach (var c in (List<object>)node["items"]) { var r = DriveWhere((Dictionary<string, object>)c, false, aliasMap); if (!r.ok) return r; res.overrides.AddRange(r.overrides); }
            return res;
        }
        return new OvR { ok = false, reason = "unexpected WHERE node '" + k + "'" };
    }

    private static OvR CoordinateJoins(Dictionary<string, object> src)
    {
        var res = new OvR();
        foreach (var stObj in (List<object>)src["joins"])
        {
            var st = (Dictionary<string, object>)stObj;
            foreach (var pObj in (List<object>)st["on"])
            {
                var p = (Dictionary<string, object>)pObj;
                if ((string)p["op"] == "=")
                {
                    res.overrides.Add(M("tbl", p["lAlias"], "col", p["lCol"], "vspec", M("sample", true)));
                    res.overrides.Add(M("tbl", p["rAlias"], "col", p["rCol"], "vspec", M("sample", true)));
                }
                else
                {
                    res.overrides.Add(M("tbl", p["rAlias"], "col", p["rCol"], "vspec", M("sample", true)));
                    res.overrides.Add(M("tbl", p["lAlias"], "col", p["lCol"], "vspec", M("satisfysample", M("op", p["op"], "want", 1))));
                }
            }
        }
        return res;
    }

    private static Dictionary<string, object> AtomKspec(Dictionary<string, object> atom, bool want)
    {
        string agg = (string)atom["agg"], op = (string)atom["op"];
        string shape = null, cmp = null;
        object comparand = atom["comparand"];
        if (op == "exists") { shape = "EXISTS"; cmp = null; comparand = null; }
        else if (op == "isnull") { shape = "SCALAR_NULL"; cmp = "IS_NULL"; }
        else if (op == "isnotnull") { shape = "SCALAR_NULL"; cmp = "IS_NOT_NULL"; }
        else if (op == "in") { shape = "COUNT_IN"; cmp = "IN"; comparand = string.Join(", ", ((List<object>)atom["comparand"]).Select(o => o.ToString())); }
        else if (op == "notin") { shape = "COUNT_IN"; cmp = "NOT_IN"; comparand = string.Join(", ", ((List<object>)atom["comparand"]).Select(o => o.ToString())); }
        else if (op == "between") { var cl = (List<object>)atom["comparand"]; shape = "COUNT_BETWEEN"; cmp = "BETWEEN"; comparand = cl[0].ToString() + " AND " + cl[1].ToString(); }
        else
        {
            cmp = op;
            switch (agg)
            {
                case "COUNT": shape = "COUNT_CMP"; break;
                case "SUM": shape = "SUM_CMP"; break;
                case "MIN": shape = "MIN_CMP"; break;
                case "MAX": shape = "MAX_CMP"; break;
                case "AVG": shape = "AVG_CMP"; break;
                case "SCALAR": shape = "SCALAR_CMP"; break;
                default: shape = "COUNT_CMP"; break;
            }
        }
        return M("shape", shape, "comparator", cmp, "comparand", comparand, "want", want ? 1 : 0);
    }

    private static DemR PlanAtom(Dictionary<string, object> atom, bool want)
    {
        var src = (Dictionary<string, object>)atom["source"];
        var tables = (List<object>)src["tables"];
        var aliasIdx = new Dictionary<string, int>();
        var aliasMap = new Dictionary<string, string[]>();
        for (int i = 0; i < tables.Count; i++)
        {
            var t = (Dictionary<string, object>)tables[i];
            string a = t["alias"] != null ? (string)t["alias"] : (string)t["table"];
            aliasIdx[a] = i;
            aliasMap[a] = new string[] { (string)t["schema"], (string)t["table"] };
        }
        var wd = DriveWhere((Dictionary<string, object>)src["where"], true, aliasMap); if (!wd.ok) return new DemR { ok = false, reason = wd.reason };
        var jc = CoordinateJoins(src); if (!jc.ok) return new DemR { ok = false, reason = jc.reason };
        var allOv = new List<object>();
        allOv.AddRange(wd.overrides); allOv.AddRange(jc.overrides);

        string agg = (string)atom["agg"], aop = (string)atom["op"];
        bool isAggVal = (agg == "SUM" || agg == "MIN" || agg == "MAX" || agg == "AVG")
                        || (agg == "SCALAR" && aop != "isnull" && aop != "isnotnull" && aop != "exists");
        if (isAggVal)
        {
            var icr = ExtractInnerColRef((string)atom["selectExpr"]);
            string col = (string)icr["col"];
            if (col != null && col != "*")
            {
                string vk = (atom["comparand"] != null && atom["comparand"].ToString().StartsWith("@")) ? "param" : "literal";
                allOv.Add(M("tbl", icr["alias"], "col", col, "vspec", M("satisfy", M("op", aop, "val", atom["comparand"], "valKind", vk, "want", want ? 1 : 0))));
            }
        }

        var perTable = new Dictionary<int, List<object>>();
        for (int i = 0; i < tables.Count; i++) perTable[i] = new List<object>();
        foreach (var oObj in allOv)
        {
            var o = (Dictionary<string, object>)oObj;
            int idx;
            if (o["tbl"] == null) idx = 0;
            else if (aliasIdx.ContainsKey((string)o["tbl"])) idx = aliasIdx[(string)o["tbl"]];
            else return new DemR { ok = false, reason = "override references unknown alias '" + o["tbl"] + "'" };
            perTable[idx].Add(M("col", o["col"], "vspec", o["vspec"]));
        }

        var kspec = AtomKspec(atom, want);
        var res = new DemR();
        for (int i = 0; i < tables.Count; i++)
        {
            var t = (Dictionary<string, object>)tables[i];
            var d = M("schema", t["schema"], "table", t["table"], "alias", t["alias"], "overrides", perTable[i]);
            if (i == 0) d["kspec"] = kspec; else d["count"] = 1;
            res.demands.Add(d);
        }
        return res;
    }

    private static DemR Propagate(Dictionary<string, object> node, bool want)
    {
        string k = (string)node["k"];
        if (k == "const")
        {
            if ((bool)node["val"] == want) return new DemR();
            return new DemR { ok = false, reason = "constant sub-predicate has the opposite fixed truth value" };
        }
        if (k == "atom") return PlanAtom(node, want);
        if (k == "not") return Propagate((Dictionary<string, object>)node["item"], !want);
        if (k == "and")
        {
            if (want)
            {
                var res = new DemR();
                foreach (var c in (List<object>)node["items"]) { var r = Propagate((Dictionary<string, object>)c, true); if (!r.ok) return r; res.demands.AddRange(r.demands); }
                return res;
            }
            return PickCheapest((List<object>)node["items"], false, "cannot drive AND false (no child falsifiable)");
        }
        if (k == "or")
        {
            if (want) return PickCheapest((List<object>)node["items"], true, "no OR branch is satisfiable");
            var res = new DemR();
            foreach (var c in (List<object>)node["items"]) { var r = Propagate((Dictionary<string, object>)c, false); if (!r.ok) return r; res.demands.AddRange(r.demands); }
            return res;
        }
        return new DemR { ok = false, reason = "unexpected node '" + k + "'" };
    }

    private static DemR PickCheapest(List<object> items, bool want, string failReason)
    {
        DemR best = null;
        foreach (var c in items)
        {
            var r = Propagate((Dictionary<string, object>)c, want);
            if (r.ok)
            {
                int n = r.demands.Count;
                if (best == null || n < best.demands.Count) best = r;
                if (n == 0) break;
            }
        }
        if (best != null) return best;
        return new DemR { ok = false, reason = failReason };
    }

    private static Dictionary<string, object> GetSeedPlan(Dictionary<string, object> tree, bool wantTrue)
    {
        string predSql = RenderPredNode(tree);
        var prop = Propagate(tree, wantTrue);
        if (!prop.ok)
            return M("skip", prop.reason, "predSql", predSql, "expectedBit", wantTrue ? 1 : 0, "tables", new List<object>());
        var byKey = new Dictionary<string, Dictionary<string, object>>();
        var order = new List<string>();
        foreach (var dObj in prop.demands)
        {
            var d = (Dictionary<string, object>)dObj;
            string key = d["schema"] + "." + d["table"];
            if (!byKey.ContainsKey(key)) { byKey[key] = M("schema", d["schema"], "table", d["table"], "demands", new List<object>()); order.Add(key); }
            var dem = M("overrides", d["overrides"]);
            if (d.ContainsKey("kspec")) dem["kspec"] = d["kspec"];
            if (d.ContainsKey("count")) dem["count"] = d["count"];
            ((List<object>)byKey[key]["demands"]).Add(dem);
        }
        var tables = order.Select(o => (object)byKey[o]).ToList();
        return M("skip", null, "predSql", predSql, "expectedBit", wantTrue ? 1 : 0, "tables", tables);
    }

    // =====================================================================
    // Per-proc parser instance (holds local-substitution state + result rows).
    // =====================================================================
    private sealed class Parser
    {
        private Dictionary<string, string> localDefs = new Dictionary<string, string>();
        private Dictionary<string, Dictionary<string, object>> localCond = new Dictionary<string, Dictionary<string, object>>();
        private List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
        private int branchId = 0;

        private static SD.TSqlParser NewParser() { return new SD.TSql170Parser(true); }

        public List<Dictionary<string, object>> ParseOneProc(string schema, string proc, string body)
        {
            rows = new List<Dictionary<string, object>>();
            branchId = 0;
            IList<SD.ParseError> errors;
            var fragment = NewParser().Parse(new StringReader(body), out errors);
            localDefs = CollectProcLocals(fragment);
            localCond = CollectProcLocalConds(fragment);
            VisitFragment(fragment, "root", schema, proc);
            foreach (var r in rows) if (r["PredicateTreeJson"] != null) r["Shape"] = "PREDTREE";
            return rows;
        }

        private void VisitFragment(SD.TSqlFragment node, string context, string schema, string proc)
        {
            if (node == null) return;
            var ifs = node as SD.IfStatement;
            if (ifs != null)
            {
                branchId++;
                var ifRow = Classify(ifs.Predicate, branchId, "IF", schema, proc, ifs.StartLine);
                ifRow["BodyDmlSeedJson"] = BodyDmlSeedJsonFor(ifs.ThenStatement);
                rows.Add(ifRow);
                VisitFragment(ifs.ThenStatement, "IF", schema, proc);
                VisitFragment(ifs.ElseStatement, "IF", schema, proc);
                return;
            }
            var wh = node as SD.WhileStatement;
            if (wh != null)
            {
                branchId++;
                rows.Add(Classify(wh.Predicate, branchId, "WHILE", schema, proc, wh.StartLine));
                VisitFragment(wh.Statement, "WHILE", schema, proc);
                return;
            }
            var sc = node as SD.SearchedCaseExpression;
            if (sc != null)
            {
                foreach (var w in sc.WhenClauses)
                {
                    branchId++;
                    rows.Add(Classify(w.WhenExpression, branchId, "CASE_WHEN", schema, proc, w.StartLine));
                }
                return;
            }
            foreach (var prop in ChildProps(node))
            {
                object val;
                try { val = prop.GetValue(node, null); } catch { continue; }
                if (val == null) continue;
                var frag = val as SD.TSqlFragment;
                if (frag != null) { VisitFragment(frag, context, schema, proc); continue; }
                var en = val as IEnumerable;
                if (en != null && !(val is string))
                    foreach (var child in en) { var cf = child as SD.TSqlFragment; if (cf != null) VisitFragment(cf, context, schema, proc); }
            }
        }

        // -----------------------------------------------------------------
        // Classify one branch predicate into a row (tree path; flat fallback).
        // -----------------------------------------------------------------
        private Dictionary<string, object> Classify(SD.BooleanExpression predicate, int bId, string context, string schema, string proc, int startLine)
        {
            var row = M(
                "SchemaName", schema, "ProcName", proc, "BranchId", bId, "StartLine", startLine, "Context", context,
                "Shape", "UNRECOGNISED", "AggregateColumn", null, "Comparator", null, "Comparand", null,
                "TargetTablesJson", "[]", "JoinsJson", null, "WhereAstJson", null,
                "PredicateTreeJson", null, "SeedPlanTrueJson", null, "SeedPlanFalseJson", null, "PredicateTreeText", null,
                "PredicateText", FragText(predicate), "UnsupportedReason", null, "BodyDmlSeedJson", null);

            // Inline single-assignment locals / expand conditional locals.
            SD.BooleanExpression workPred = predicate;
            bool haveLocals = localDefs.Count > 0 || localCond.Count > 0;
            if (haveLocals)
            {
                int depth = 0;
                while (depth < 12)
                {
                    var refsList = new List<string>();
                    GetFragmentVarRefs(workPred, refsList);
                    var uniq = refsList.Distinct().ToList();

                    string condRef = localCond.Count > 0 ? uniq.FirstOrDefault(x => localCond.ContainsKey(x)) : null;
                    if (condRef != null)
                    {
                        var cc = localCond[condRef];
                        string ptext = FragText(workPred);
                        string esc = Regex.Escape(condRef) + "\\b";
                        string thenP = Regex.Replace(ptext, esc, m => "(" + cc["thenVal"] + ")");
                        string elseP = Regex.Replace(ptext, esc, m => "(" + cc["elseVal"] + ")");
                        string expanded = "((" + cc["cond"] + ") AND (" + thenP + ")) OR ((NOT (" + cc["cond"] + ")) AND (" + elseP + "))";
                        var rp = ReparseBoolExpr(expanded);
                        if (rp == null) break;
                        workPred = rp; depth++; continue;
                    }

                    var sub = uniq.Where(x => localDefs.ContainsKey(x)).ToList();
                    if (sub.Count == 0) break;
                    string txt = FragText(workPred);
                    foreach (var nm in sub.OrderByDescending(s => s.Length))
                    {
                        string defv = localDefs[nm];
                        txt = Regex.Replace(txt, Regex.Escape(nm) + "\\b", m => "(" + defv + ")");
                    }
                    var rp2 = ReparseBoolExpr(txt);
                    if (rp2 == null) break;
                    workPred = rp2; depth++;
                }
            }

            var tree = BuildPredTree(workPred);
            if (tree.ok)
            {
                row["PredicateTreeJson"] = Json(tree.node);
                row["PredicateTreeText"] = RenderPredNode(tree.node);
                row["SeedPlanTrueJson"] = Json(GetSeedPlan(tree.node, true));
                row["SeedPlanFalseJson"] = Json(GetSeedPlan(tree.node, false));
                var tbls = CollectTreeTables(tree.node);
                if (tbls.Count > 0)
                    row["TargetTablesJson"] = "[" + string.Join(",", tbls.Select(t => Json(t))) + "]";
                return row;
            }

            // ---- flat fallback (legacy shape vocabulary) ----
            return ClassifyFlat(row, predicate);
        }

        private Dictionary<string, object> ClassifyFlat(Dictionary<string, object> row, SD.BooleanExpression predicate)
        {
            // EXISTS / NOT EXISTS
            bool? negated = null; SD.BooleanExpression p = predicate;
            if (p is SD.ExistsPredicate) negated = false;
            else
            {
                var bnot = p as SD.BooleanNotExpression;
                if (bnot != null && bnot.Expression is SD.ExistsPredicate) { negated = true; p = bnot.Expression; }
            }
            if (negated != null)
            {
                row["Shape"] = negated.Value ? "NOT_EXISTS" : "EXISTS";
                var qe = ((SD.ExistsPredicate)p).Subquery.QueryExpression as SD.QuerySpecification;
                if (qe == null) return Unsupported(row, "EXISTS subquery is not a simple query spec");
                return ApplySubquery(row, qe, true);
            }

            var bc = predicate as SD.BooleanComparisonExpression;
            if (bc != null)
            {
                string cmp; CmpOps.TryGetValue(bc.ComparisonType.ToString(), out cmp);
                var info = AggregateInfo(bc.FirstExpression); SD.ScalarExpression comparandExpr = bc.SecondExpression;
                if (info == null) { info = AggregateInfo(bc.SecondExpression); comparandExpr = bc.FirstExpression; }
                if (info == null) return Unsupported(row, "comparison does not involve an aggregate/scalar subquery");
                if (cmp == null) return Unsupported(row, "unsupported comparison operator");
                string lit = LiteralText(comparandExpr);
                if (lit == null)
                {
                    var vr = comparandExpr as SD.VariableReference;
                    if (vr != null) lit = vr.Name;
                    else return Unsupported(row, "comparand is not a literal or @parameter (variable/expression)");
                }
                string agg = (string)info["Aggregate"];
                row["Shape"] = agg == "COUNT" ? "COUNT_CMP" : agg == "SUM" ? "SUM_CMP" : agg == "MIN" ? "MIN_CMP"
                             : agg == "MAX" ? "MAX_CMP" : agg == "AVG" ? "AVG_CMP" : agg == "SCALAR" ? "SCALAR_CMP" : "UNRECOGNISED";
                row["AggregateColumn"] = info["ColumnText"]; row["Comparator"] = cmp; row["Comparand"] = lit;
                return ApplySubquery(row, (SD.QuerySpecification)info["QuerySpec"], false);
            }

            var ip = predicate as SD.InPredicate;
            if (ip != null)
            {
                var info = AggregateInfo(ip.Expression);
                if (info == null || (string)info["Aggregate"] != "COUNT") return Unsupported(row, "IN predicate not over COUNT(...) ");
                if (ip.Subquery != null) return Unsupported(row, "IN (subquery) not supported");
                var vals = ip.Values.Select(v => LiteralText(v)).ToList();
                if (vals.Contains(null)) return Unsupported(row, "IN list has a non-literal value");
                row["Shape"] = "COUNT_IN"; row["AggregateColumn"] = info["ColumnText"];
                row["Comparator"] = ip.NotDefined ? "NOT_IN" : "IN"; row["Comparand"] = string.Join(", ", vals);
                return ApplySubquery(row, (SD.QuerySpecification)info["QuerySpec"], false);
            }

            var te = predicate as SD.BooleanTernaryExpression;
            if (te != null && te.TernaryExpressionType.ToString().StartsWith("Between"))
            {
                var info = AggregateInfo(te.FirstExpression);
                if (info == null || (string)info["Aggregate"] != "COUNT") return Unsupported(row, "BETWEEN not over COUNT(...) ");
                string a = LiteralText(te.SecondExpression), b = LiteralText(te.ThirdExpression);
                if (a == null || b == null) return Unsupported(row, "BETWEEN bounds are not literals");
                row["Shape"] = "COUNT_BETWEEN"; row["AggregateColumn"] = info["ColumnText"];
                row["Comparator"] = "BETWEEN"; row["Comparand"] = a + " AND " + b;
                return ApplySubquery(row, (SD.QuerySpecification)info["QuerySpec"], false);
            }

            var inn = predicate as SD.BooleanIsNullExpression;
            if (inn != null)
            {
                var info = AggregateInfo(inn.Expression);
                if (info == null || (string)info["Aggregate"] != "SCALAR") return Unsupported(row, "IS NULL not over a scalar subquery");
                row["Shape"] = "SCALAR_NULL"; row["AggregateColumn"] = info["ColumnText"];
                row["Comparator"] = inn.IsNot ? "IS_NOT_NULL" : "IS_NULL";
                return ApplySubquery(row, (SD.QuerySpecification)info["QuerySpec"], false);
            }

            return Unsupported(row, "predicate shape not in the v0.10 grammar");
        }

        private static Dictionary<string, object> Unsupported(Dictionary<string, object> r, string why)
        {
            r["Shape"] = "UNRECOGNISED"; r["UnsupportedReason"] = why; return r;
        }

        private static Dictionary<string, object> ApplySubquery(Dictionary<string, object> r, SD.QuerySpecification qspec, bool allowJoin)
        {
            var ft = GetFromTables(qspec);
            if (!ft.ok) return Unsupported(r, ft.reason);
            if (ft.joins.Count > 0 && !allowJoin) return Unsupported(r, "join in subquery is only seedable for EXISTS / NOT EXISTS in this cut");
            if (ft.joins.Count > 0 && ft.tables.Count != 2) return Unsupported(r, "only 2-table inner joins are seedable in this cut");
            r["TargetTablesJson"] = "[" + string.Join(",", ft.tables.Select(t => Json(t))) + "]";
            if (ft.joins.Count > 0) r["JoinsJson"] = "[" + string.Join(",", ft.joins.Select(j => Json(j))) + "]";
            var whereExpr = qspec.WhereClause != null ? qspec.WhereClause.SearchCondition : null;
            var wc = GetWhereDnf(whereExpr);
            if (!wc.ok) return Unsupported(r, wc.reason);
            if (wc.terms.Count > 0)
            {
                var termsJson = wc.terms.Select(term => "[" + string.Join(",", term.Select(c => Json(c))) + "]");
                r["WhereAstJson"] = "[" + string.Join(",", termsJson) + "]";
            }
            return r;
        }

        // -----------------------------------------------------------------
        // Local-variable collection + reparse.
        // -----------------------------------------------------------------
        private static void GetFragmentVarRefs(SD.TSqlFragment node, List<string> acc)
        {
            if (node == null) return;
            var vr = node as SD.VariableReference;
            if (vr != null) { acc.Add(vr.Name); return; }
            foreach (var prop in ChildProps(node))
            {
                object v; try { v = prop.GetValue(node, null); } catch { continue; }
                if (v == null) continue;
                var frag = v as SD.TSqlFragment;
                if (frag != null) { GetFragmentVarRefs(frag, acc); continue; }
                var en = v as IEnumerable;
                if (en != null && !(v is string))
                    foreach (var c in en) { var cf = c as SD.TSqlFragment; if (cf != null) GetFragmentVarRefs(cf, acc); }
            }
        }

        private static void CollectAssignNodes(SD.TSqlFragment node, List<SD.TSqlFragment> acc)
        {
            if (node == null) return;
            if (node is SD.DeclareVariableStatement || node is SD.SetVariableStatement) acc.Add(node);
            foreach (var prop in ChildProps(node))
            {
                object v; try { v = prop.GetValue(node, null); } catch { continue; }
                if (v == null) continue;
                var frag = v as SD.TSqlFragment;
                if (frag != null) { CollectAssignNodes(frag, acc); continue; }
                var en = v as IEnumerable;
                if (en != null && !(v is string))
                    foreach (var c in en) { var cf = c as SD.TSqlFragment; if (cf != null) CollectAssignNodes(cf, acc); }
            }
        }

        private static Dictionary<string, string> CollectProcLocals(SD.TSqlFragment fragment)
        {
            var defs = new Dictionary<string, string>();
            var counts = new Dictionary<string, int>();
            var nodes = new List<SD.TSqlFragment>();
            CollectAssignNodes(fragment, nodes);
            foreach (var st in nodes)
            {
                var dv = st as SD.DeclareVariableStatement;
                if (dv != null)
                {
                    foreach (var d in dv.Declarations)
                        if (d.Value != null)
                        {
                            string n = d.VariableName.Value;
                            counts[n] = counts.ContainsKey(n) ? counts[n] + 1 : 1;
                            defs[n] = FragText(d.Value);
                        }
                    continue;
                }
                var sv = st as SD.SetVariableStatement;
                if (sv != null && sv.Expression != null)
                {
                    string n = sv.Variable.Name;
                    counts[n] = counts.ContainsKey(n) ? counts[n] + 1 : 1;
                    defs[n] = FragText(sv.Expression);
                }
            }
            var outd = new Dictionary<string, string>();
            foreach (var k in defs.Keys) if (counts[k] == 1) outd[k] = defs[k];
            return outd;
        }

        private static IList<SD.TSqlStatement> CollectProcBodyStatements(SD.TSqlFragment fragment)
        {
            var script = fragment as SD.TSqlScript;
            if (script != null)
                foreach (var b in script.Batches)
                    foreach (var st in b.Statements)
                    {
                        var slProp = st.GetType().GetProperty("StatementList");
                        if (st.GetType().Name.IndexOf("Procedure", StringComparison.Ordinal) >= 0 && slProp != null)
                        {
                            var sl = slProp.GetValue(st, null) as SD.StatementList;
                            if (sl != null) return sl.Statements;
                        }
                    }
            return new List<SD.TSqlStatement>();
        }

        private static void CollectAssignWithGuards(SD.TSqlStatement node, List<Dictionary<string, object>> guard, List<Dictionary<string, object>> acc)
        {
            if (node == null) return;
            var ifs = node as SD.IfStatement;
            if (ifs != null)
            {
                var c = ifs.Predicate;
                var gThen = new List<Dictionary<string, object>>(guard); gThen.Add(M("cond", c, "neg", false));
                CollectAssignWithGuards(ifs.ThenStatement, gThen, acc);
                if (ifs.ElseStatement != null)
                {
                    var gElse = new List<Dictionary<string, object>>(guard); gElse.Add(M("cond", c, "neg", true));
                    CollectAssignWithGuards(ifs.ElseStatement, gElse, acc);
                }
                return;
            }
            var be = node as SD.BeginEndBlockStatement;
            if (be != null) { foreach (var s in be.StatementList.Statements) CollectAssignWithGuards(s, guard, acc); return; }
            var dv = node as SD.DeclareVariableStatement;
            if (dv != null)
            {
                foreach (var d in dv.Declarations) if (d.Value != null) acc.Add(M("var", d.VariableName.Value, "val", FragText(d.Value), "guard", new List<Dictionary<string, object>>(guard)));
                return;
            }
            var sv = node as SD.SetVariableStatement;
            if (sv != null && sv.Expression != null) acc.Add(M("var", sv.Variable.Name, "val", FragText(sv.Expression), "guard", new List<Dictionary<string, object>>(guard)));
        }

        private static Dictionary<string, Dictionary<string, object>> CollectProcLocalConds(SD.TSqlFragment fragment)
        {
            var acc = new List<Dictionary<string, object>>();
            foreach (var s in CollectProcBodyStatements(fragment)) CollectAssignWithGuards(s, new List<Dictionary<string, object>>(), acc);
            var outd = new Dictionary<string, Dictionary<string, object>>();
            foreach (var v in acc.Select(a => (string)a["var"]).Distinct())
            {
                var asg = acc.Where(a => (string)a["var"] == v).ToList();
                if (asg.Count == 2)
                {
                    var g0 = (List<Dictionary<string, object>>)asg[0]["guard"];
                    var g1 = (List<Dictionary<string, object>>)asg[1]["guard"];
                    if (g0.Count == 1 && g1.Count == 1
                        && ReferenceEquals(g0[0]["cond"], g1[0]["cond"])
                        && (bool)g0[0]["neg"] != (bool)g1[0]["neg"])
                    {
                        var thenA = !(bool)g0[0]["neg"] ? asg[0] : asg[1];
                        var elseA = (bool)g0[0]["neg"] ? asg[0] : asg[1];
                        outd[v] = M("cond", FragText((SD.TSqlFragment)g0[0]["cond"]), "thenVal", thenA["val"], "elseVal", elseA["val"]);
                    }
                }
            }
            return outd;
        }

        private static SD.BooleanExpression ReparseBoolExpr(string text)
        {
            var p = NewParser();
            IList<SD.ParseError> err;
            var frag = p.Parse(new StringReader("IF (" + text + ") SET @uagz = 1;"), out err);
            if (err != null && err.Count > 0) return null;
            var script = frag as SD.TSqlScript;
            if (script != null)
                foreach (var b in script.Batches)
                    foreach (var st in b.Statements)
                    {
                        var ifs = st as SD.IfStatement;
                        if (ifs != null) return ifs.Predicate;
                    }
            return null;
        }
    }

    // ---------------------------------------------------------------------
    // Flat-path helpers (shared, stateless).
    // ---------------------------------------------------------------------
    private static EqR JoinEqualities(SD.BooleanExpression boolExpr)
    {
        var outR = new EqR();
        if (boolExpr == null) { outR.ok = false; outR.reason = "join has no ON condition"; return outR; }
        var stack = new Stack<SD.BooleanExpression>();
        stack.Push(boolExpr);
        while (stack.Count > 0)
        {
            var n = stack.Pop();
            var bp = n as SD.BooleanParenthesisExpression;
            if (bp != null) { stack.Push(bp.Expression); continue; }
            var bb = n as SD.BooleanBinaryExpression;
            if (bb != null)
            {
                if (bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And) { stack.Push(bb.FirstExpression); stack.Push(bb.SecondExpression); continue; }
                outR.ok = false; outR.reason = "join ON uses OR composition"; return outR;
            }
            var bc = n as SD.BooleanComparisonExpression;
            if (bc != null && bc.ComparisonType == SD.BooleanComparisonType.Equals)
            {
                var l = bc.FirstExpression as SD.ColumnReferenceExpression;
                var r = bc.SecondExpression as SD.ColumnReferenceExpression;
                if (l != null && r != null)
                {
                    var li = l.MultiPartIdentifier.Identifiers; var ri = r.MultiPartIdentifier.Identifiers;
                    string la = li.Count >= 2 ? li[li.Count - 2].Value : null;
                    string ra = ri.Count >= 2 ? ri[ri.Count - 2].Value : null;
                    outR.eqs.Add(M("lAlias", la, "lCol", li[li.Count - 1].Value, "rAlias", ra, "rCol", ri[ri.Count - 1].Value));
                    continue;
                }
                outR.ok = false; outR.reason = "join ON is not column = column"; return outR;
            }
            outR.ok = false; outR.reason = "join ON is not an equality (or AND of equalities)"; return outR;
        }
        return outR;
    }

    private static FromR CollectJoinTables(SD.TableReference reference)
    {
        var nt = reference as SD.NamedTableReference;
        if (nt != null)
        {
            var info = TableRefInfo(reference);
            if (info == null) return new FromR { ok = false, reason = "FROM table is not a plain named table" };
            var r = new FromR(); r.tables.Add(info); return r;
        }
        var qj = reference as SD.QualifiedJoin;
        if (qj != null)
        {
            if (qj.QualifiedJoinType != SD.QualifiedJoinType.Inner) return new FromR { ok = false, reason = "only INNER joins are seedable in this cut" };
            var a = CollectJoinTables(qj.FirstTableReference); if (!a.ok) return a;
            var b = CollectJoinTables(qj.SecondTableReference); if (!b.ok) return b;
            var eq = JoinEqualities(qj.SearchCondition); if (!eq.ok) return new FromR { ok = false, reason = eq.reason };
            var r = new FromR();
            r.tables.AddRange(a.tables); r.tables.AddRange(b.tables);
            r.joins.AddRange(a.joins); r.joins.AddRange(b.joins); r.joins.AddRange(eq.eqs);
            return r;
        }
        return new FromR { ok = false, reason = "FROM is a derived table / TVF / APPLY (not a plain table or inner join)" };
    }

    private static FromR GetFromTables(SD.QuerySpecification querySpec)
    {
        if (querySpec.FromClause == null) return new FromR { ok = false, reason = "subquery has no FROM clause" };
        var refs = querySpec.FromClause.TableReferences;
        if (refs.Count != 1) return new FromR { ok = false, reason = "comma-separated FROM (old-style join) not supported" };
        var cj = CollectJoinTables(refs[0]);
        if (!cj.ok) return new FromR { ok = false, reason = cj.reason };
        return cj;
    }

    private static DnfR GetWhereDnf(SD.BooleanExpression boolExpr)
    {
        if (boolExpr == null) return new DnfR();
        var n = boolExpr;
        var bp = n as SD.BooleanParenthesisExpression;
        if (bp != null) return GetWhereDnf(bp.Expression);
        var bb = n as SD.BooleanBinaryExpression;
        if (bb != null)
        {
            var L = GetWhereDnf(bb.FirstExpression); if (!L.ok) return L;
            var R = GetWhereDnf(bb.SecondExpression); if (!R.ok) return R;
            var terms = new List<List<Dictionary<string, object>>>();
            if (bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.Or)
            {
                terms.AddRange(L.terms); terms.AddRange(R.terms);
            }
            else if (bb.BinaryExpressionType == SD.BooleanBinaryExpressionType.And)
            {
                if (L.terms.Count == 0) terms.AddRange(R.terms);
                else if (R.terms.Count == 0) terms.AddRange(L.terms);
                else foreach (var lt in L.terms) foreach (var rt in R.terms) { var m = new List<Dictionary<string, object>>(lt); m.AddRange(rt); terms.Add(m); }
            }
            else return new DnfR { ok = false, reason = "WHERE uses unsupported boolean operator " + bb.BinaryExpressionType };
            if (terms.Count > 16) return new DnfR { ok = false, reason = "WHERE expands to too many DNF terms (>16)" };
            return new DnfR { terms = terms };
        }
        var leaf = WhereLeaf(n);
        if (!leaf.ok) return new DnfR { ok = false, reason = leaf.reason };
        var single = new DnfR();
        single.terms.Add(new List<Dictionary<string, object>> { leaf.conj });
        return single;
    }

    // =====================================================================
    // SQLCLR entry points.
    // =====================================================================
    [SqlProcedure]
    public static void ParseDatabasePredicates(SqlString schemaFilter)
    {
        string scope = schemaFilter.IsNull ? "*" : schemaFilter.Value;
        RunScope(scope, null);
    }

    [SqlProcedure]
    public static void ParseProcedurePredicates(SqlString schema, SqlString procName)
    {
        RunScope(schema.IsNull ? "dbo" : schema.Value, procName.IsNull ? null : procName.Value);
    }

    private static void RunScope(string scope, string procName)
    {
        using (var conn = new SqlConnection("context connection=true"))
        {
            conn.Open();

            // Clear the inbox for the scope.
            using (var clr = conn.CreateCommand())
            {
                clr.CommandText = "TestGen.ClearPredicateInbox";
                clr.CommandType = CommandType.StoredProcedure;
                if (scope != "*") clr.Parameters.AddWithValue("@SchemaName", scope);
                if (procName != null) clr.Parameters.AddWithValue("@ProcName", procName);
                clr.ExecuteNonQuery();
            }

            // Resolve target procedures (read fully before writing on the same conn).
            var procs = new List<string[]>();
            using (var pc = conn.CreateCommand())
            {
                if (procName != null)
                {
                    pc.CommandText =
                        "SELECT s.name AS sch, o.name AS nm, m.definition " +
                        "FROM sys.sql_modules m JOIN sys.objects o ON o.object_id=m.object_id " +
                        "JOIN sys.schemas s ON s.schema_id=o.schema_id " +
                        "WHERE o.type='P' AND s.name=@s AND o.name=@p";
                    pc.Parameters.AddWithValue("@s", scope);
                    pc.Parameters.AddWithValue("@p", procName);
                }
                else
                {
                    pc.CommandText =
                        "SELECT s.name AS sch, o.name AS nm, m.definition " +
                        "FROM sys.sql_modules m JOIN sys.objects o ON o.object_id=m.object_id " +
                        "JOIN sys.schemas s ON s.schema_id=o.schema_id " +
                        "WHERE o.type='P' AND o.is_ms_shipped=0 " +
                        "  AND (@s = '*' OR s.name = @s) " +
                        "  AND s.name NOT IN ('sys','tSQLt','TestGen','TestGenLog') " +
                        "  AND s.name NOT LIKE 'test[_]%' " +
                        "  AND o.name NOT LIKE '%[_]cov' AND o.name NOT LIKE '%[_]covfn' AND o.name NOT LIKE '%[_]orig' " +
                        "ORDER BY s.name, o.name";
                    pc.Parameters.AddWithValue("@s", scope);
                }
                using (var rd = pc.ExecuteReader())
                    while (rd.Read())
                        procs.Add(new string[] { rd.GetString(0), rd.GetString(1), rd.IsDBNull(2) ? "" : rd.GetString(2) });
            }

            Guid runId = Guid.NewGuid();
            int grand = 0, unrec = 0;
            foreach (var pr in procs)
            {
                var rows = new Parser().ParseOneProc(pr[0], pr[1], pr[2]);
                foreach (var r in rows)
                {
                    WriteInboxRow(conn, runId, r);
                    grand++;
                    if ((string)r["Shape"] == "UNRECOGNISED") unrec++;
                }
            }

            if (SqlContext.Pipe != null)
                SqlContext.Pipe.Send(string.Format(CultureInfo.InvariantCulture,
                    "Wrote {0} ParsedPredicate rows ({1} UNRECOGNISED) over {2} procedure(s) under RunId {3}.",
                    grand, unrec, procs.Count, runId));
        }
    }

    private static void AddParam(SqlCommand cmd, string name, object value)
    {
        cmd.Parameters.AddWithValue(name, value ?? (object)DBNull.Value);
    }

    private static void WriteInboxRow(SqlConnection conn, Guid runId, Dictionary<string, object> r)
    {
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "TestGen.AddParsedPredicate";
            cmd.CommandType = CommandType.StoredProcedure;
            cmd.Parameters.AddWithValue("@RunId", runId);
            AddParam(cmd, "@SchemaName", r["SchemaName"]);
            AddParam(cmd, "@ProcName", r["ProcName"]);
            cmd.Parameters.AddWithValue("@BranchId", Convert.ToInt32(r["BranchId"]));
            AddParam(cmd, "@Shape", r["Shape"]);
            AddParam(cmd, "@PredicateText", r["PredicateText"]);
            AddParam(cmd, "@StartLine", r["StartLine"]);
            AddParam(cmd, "@Context", r["Context"]);
            AddParam(cmd, "@AggregateColumn", r["AggregateColumn"]);
            AddParam(cmd, "@Comparator", r["Comparator"]);
            AddParam(cmd, "@Comparand", r["Comparand"]);
            AddParam(cmd, "@TargetTablesJson", r["TargetTablesJson"]);
            AddParam(cmd, "@JoinsJson", r["JoinsJson"]);
            AddParam(cmd, "@WhereAstJson", r["WhereAstJson"]);
            AddParam(cmd, "@PredicateTreeJson", r["PredicateTreeJson"]);
            AddParam(cmd, "@SeedPlanTrueJson", r["SeedPlanTrueJson"]);
            AddParam(cmd, "@SeedPlanFalseJson", r["SeedPlanFalseJson"]);
            AddParam(cmd, "@UnsupportedReason", r["UnsupportedReason"]);
            AddParam(cmd, "@BodyDmlSeedJson", r.ContainsKey("BodyDmlSeedJson") ? r["BodyDmlSeedJson"] : null);
            cmd.Parameters.AddWithValue("@ParserVersion", ParserSignature);
            var outp = cmd.Parameters.Add("@InboxId", SqlDbType.Int);
            outp.Direction = ParameterDirection.Output;
            cmd.ExecuteNonQuery();
        }
    }
}
