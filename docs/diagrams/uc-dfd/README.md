# Use case and data flow diagrams

Source: Analysis and Design Study v2.5 (English edition) only.

- `png/`, `svg/`: UC-0..UC-10 (UML 2.5 use case diagrams), DFD-0 context, DFD-1A/1B (Level 1), DFD-4/6/7/8/9/10/11/12 (Level 2), legends.
- `generator/`: model and renderers. Run from a work directory with an `out/` folder:
  `python3 ucsvg.py && python3 dfd.py && python3 legend.py && python3 export.py && node build.js`
  (needs graphviz, cairosvg and the `docx` npm package).
- Document: `../../Masslak_Use_Case_and_Data_Flow_Diagrams_v1.0.docx`.
