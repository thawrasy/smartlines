# ADR 0016: The financial statements module of M5

Status: decided by the database architect, building the owner's request of 2026-10-18 (docs/31 decision 25, docs/03
section 10). The credit rating link the owner named is a later phase and is not built.

## Context

The owner asked for a balance sheet module in the facilities section:
- statements of a standalone company, and of a holding, which may have consolidated or standalone statements, entered
  with all their units to study the balance sheet;
- a report of every breach that the statements cause under the bank covenants;
- the liquidity routed to the bank, to measure how the company keeps its commitments;
- later, a link to a credit rating system.

The model already held statement headers and lines, monthly account figures, bank flows, the formula library and the
covenant engine's results (S2-b). What it lacked:
- the units of a consolidated statement;
- the rule that only a holding consolidates;
- the auditor and opinion of an audited statement;
- analysis measures that are not covenants;
- a relational record of which statements a test read (only its JSON snapshot had it);
- a breach report and a flow performance measure;
- confirmation of a flow entry;
- the flow kind list;
- the revenue estimate of Q-FIN-05.

## Decision

1. **Units.** `fin.ConsolidationMember` holds the units of a consolidated statement:
   - its statement only through a composite key on the basis;
   - the holding as the one PARENT unit (FULL, no percentage);
   - each subsidiary, associate and joint venture with its method and ownership;
   - the dates it came in or went out during the period;
   - its own standalone statement, if any.
2. **Holding.** `045_financial_statements.sql` refuses a consolidated statement of a company that is not a holding,
   and the submission of one without its PARENT unit and another unit (50061).
3. **Statement life.** A statement is written as a draft. Its header, lines and units change only while it is a draft,
   and its status moves as spec 12 section 8 says (50060). The header trigger is built from the table's columns, so a
   later column is frozen unless named. An audited statement names its auditor and opinion, and its approver is not
   its preparer (checks).
4. **Analysis.**
   - `MeasureFormula.Scope` gains ANALYSIS, and `ResultUnit` gains DAYS, for analysis formulas only. A covenant's unit
     copy cannot hold DAYS, so no covenant measures in days.
   - `fin.StatementRatio` keeps one computed measure per statement and formula, with its snapshot, or the reason it
     could not be computed.
5. **Test links.** `obl.CovenantTestStatement` records the statements an automatic evaluation read.
   - A trigger writes it from the snapshot when the test becomes EVALUATED. The trigger is set to run last, after the
     checks of 044.
   - The application cannot write it (DENY).
   - A test with links cannot be deleted. An evaluated test could not change anyway.
6. **Breach report.** `fin.v_StatementBreachReport` lists the breach or early warning of the latest evaluation of each
   covenant period that read statements, with:
   - the statement, its version and basis, flagged if superseded since;
   - the covenant and its clause;
   - the facility and its bank (agent, else lead, else the largest share at the approved revision);
   - the breach record.
7. **Flows.**
   - `fin.BankFlowEntry` takes its kind from the FLOW_KIND list only, through a composite key on the list's code.
   - It has a DRAFT/CONFIRMED status, confirmed by someone other than the person who entered it.
   - It is entered at the level of the bank or per facility, not both, for a month (50062).
8. **Flow performance.** `fin.fn_BankFlowPerformance(@AsOf)` measures each flow or revenue-share covenant valid on the
   date. It returns:
   - its window;
   - the confirmed flows to the facility's banks from the company or the obligation's companies;
   - the flows awaiting confirmation;
   - the remaining amount and the monthly rate needed;
   - the achievement and a state;
   - for a revenue share, the revenue read: the approved annual statement of the year or the year before, or the
     approved `fin.RevenueEstimate`.
9. **Readers.**
   - The views and the function are readable by `tp_app` and `tp_readonly`; the row filters of the tables they read
     apply.
   - `fin.v_ConsolidationUnits` shows each unit with its own approved statement and the ownership on record.
   - The new permission `fin.stats.confirm` (TM) confirms flows.
10. **Credit rating.** It is not built. Spec 12 section 11 records what a rating system would read: the approved
    statements with their units, the analysis measures, the breach report and the flow performance, each by stable
    key.

## Consequences

- The database grows by four tables to 203.
- Tests: FS1 to FS11 in `db/tests/financial_statements_tests.sql` (CI step 19b). Disabling any of the five triggers
  makes its tests fail.
- RF28's deletion case now stops at the statement link's key (547), before the freeze trigger.
- BR-FIN-016, approved by the owner as written (2026-10-18): a flow given to one facility counts for it alone, and a
  bank-level flow counts for every covenant of that bank's facilities.
- The performance function computes on read. A daily snapshot for history and alerts is left to the jobs of S2-b.
