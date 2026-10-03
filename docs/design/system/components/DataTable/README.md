The portal table: sticky-style header on `surface-container-low`, hairline rows, tabular numbers aligned to the end and a status column.

- Props: `columns` ([{key, label, align: "end", mono, status}]), `rows` (objects keyed by column; a status cell takes {status, label}).
- Wrap wide tables in their own horizontal scroll. Row actions go in an overflow menu at the end.
