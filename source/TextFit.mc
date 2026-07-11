import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

// Adaptive text sizing for round screens: picks the largest system
// font that makes a given line of text fit within the screen chord
// at its vertical position. Stateless helpers, usable from any view.
module TextFit {

    // Font ladder, largest to smallest. Built lazily because module
    // initialization order for Toybox enum references is undefined.
    var _fonts as Lang.Array or Null = null;

    function fonts() as Lang.Array {
        if (_fonts == null) {
            _fonts = [
                Graphics.FONT_LARGE,
                Graphics.FONT_MEDIUM,
                Graphics.FONT_SMALL,
                Graphics.FONT_TINY,
                Graphics.FONT_XTINY
            ];
        }
        return _fonts as Lang.Array;
    }

    // Usable text width (round-screen chord) at vertical position y,
    // minus a small safety margin.
    function chordWidth(dc as Graphics.Dc, y as Lang.Float) as Lang.Float {
        var r = dc.getWidth() / 2.0;
        var dy = y - r;
        if (dy < 0) {
            dy = -dy;
        }
        if (dy >= r) {
            return 0.0;
        }
        return 2.0 * Math.sqrt(r * r - dy * dy) - 12.0;
    }

    // Picks the largest font (starting at fonts()[startIdx]) that
    // fits `text` within the round screen at a line starting at yTop.
    // For text in the top half the narrowest point is the top edge
    // of the line; in the bottom half it's the bottom edge.
    function fitFont(dc as Graphics.Dc, text as Lang.String,
                     startIdx as Lang.Number, yTop as Lang.Float,
                     topHalf as Lang.Boolean) as Graphics.FontType {
        var ladder = fonts();
        for (var i = startIdx; i < ladder.size(); i++) {
            var f = ladder[i] as Graphics.FontType;
            var edgeY = topHalf ? yTop : yTop + dc.getFontHeight(f);
            if (dc.getTextWidthInPixels(text, f) <= chordWidth(dc, edgeY)) {
                return f;
            }
        }
        return ladder[ladder.size() - 1] as Graphics.FontType;
    }
}
