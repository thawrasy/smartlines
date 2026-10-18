"""db/tools/fitness.py: the architecture rules CI checks on the built database (independent review, round 9, Team).
A new foreign key without an index, a new or wider SECURITY DEFINER grant, anything granted to PUBLIC and a table with
no data class fail; baseline entries that no longer exist are reported."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("fitness", ROOT / "db" / "tools" / "fitness.py")
fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fit)

BASE = {"unindexed_foreign_keys": ["a.t.t_x_fkey", "a.t.t_gone_fkey"],
        "definer_functions": {"sys.f(integer)": ["masslak_app"], "sys.gone()": []}}


def found(**over):
    d = {"unindexed_foreign_keys": ["a.t.t_x_fkey"], "definer_functions": {"sys.f(integer)": ["masslak_app"]},
         "public_definer_functions": [], "public_relations": [], "unclassified_tables": []}
    d.update(over)
    return d


def test_the_accepted_state_passes_and_stale_entries_are_reported():
    bad, stale = fit.check(found(), BASE)
    assert bad == []
    assert "unindexed_foreign_keys: a.t.t_gone_fkey" in stale and "definer_functions: sys.gone()" in stale


def test_a_new_unindexed_foreign_key_fails():
    bad, _ = fit.check(found(unindexed_foreign_keys=["a.t.t_x_fkey", "b.u.u_y_fkey"]), BASE)
    assert bad == ["foreign key without an index: b.u.u_y_fkey (add the index in the same schema file)"]


def test_a_new_definer_function_or_a_wider_grant_fails():
    bad, _ = fit.check(found(definer_functions={"sys.f(integer)": ["masslak_app", "masslak_api"], "sys.g()": ["masslak_app"]}), BASE)
    assert "sys.f(integer): masslak_api can execute it, the baseline does not grant it" in bad
    assert any(b.startswith("SECURITY DEFINER function not in the baseline: sys.g()") for b in bad)


def test_public_grants_and_unclassified_tables_always_fail():
    bad, _ = fit.check(found(public_definer_functions=["sys.f(integer)"], public_relations=["a.t"],
                             unclassified_tables=["a.new"]), BASE)
    assert len(bad) == 3
