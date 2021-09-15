# Design document

The GC pacer design document is generated from the `.src.md` file in this
directory.
It contains LaTeX formulas which Markdown cannot render, so they're
rendered by an external open-source tool,
[md-latex](https://github.com/mknyszek/md-tools).

Then, because Gitiles' markdown viewer can't render SVGs, run

```
./svg2png.bash
cd pacer-plots
./svg2png.bash
cd ..
```

And go back and replace all instances of SVG with PNG in the final document.

Note that `svg2png.bash` requires both ImageMagick and Google Chrome.

