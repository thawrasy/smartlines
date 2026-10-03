Outlined (default) and filled text fields with a label above, helper text below and an error state.

- Props: `label`, `value`, `placeholder`, `hint`, `error`, `icon` (leading), `filled`, `required`, `type`, `dir` (set "ltr" for phone numbers, emails and codes), `multiline`.
- The resting border is `outline` (3:1 or more); focus thickens it in `primary`; errors use `error` and replace the hint.
- Validate on blur. Never use the placeholder as the label.
