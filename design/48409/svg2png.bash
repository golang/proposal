#!/bin/bash

for input in *.svg; do
	output=${input%.*}.png
	google-chrome --headless --window-size=1920,1080 --disable-gpu --screenshot $input
	convert screenshot.png -trim $output
done
rm screenshot.png
