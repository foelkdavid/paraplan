module paraplan::svg;
import std::io, std::core::string;
import bmu::sys;
import paraplan::plan;

// The sheet as SVG at true paper size: width/height in mm, coordinates in metres, so printing at 100 % gives the
// chosen scale (1:50 / 1:100 / 1:200). One <g> per level.

fn String hex(plan::Color c) => string::tformat("#%02x%02x%02x", c.r, c.g, c.b);

fn void path(DString* s, plan::Vec[] p, bool close)
{
	foreach (i, v : p) s.appendf("%s%.4f %.4f", i == 0 ? "M" : " L", v.x, v.y);
	if (close) s.append(" Z");
}

fn void escape(DString* s, String t)
{
	foreach (c : t)
	{
		switch (c)
		{
			case '<': s.append("&lt;");
			case '>': s.append("&gt;");
			case '&': s.append("&amp;");
			case '"': s.append("&quot;");
			default: s.append_char(c);
		}
	}
}

fn bool write(String file) => @pool()
{
	DString s;
	s.tinit(1 << 16);
	float w = plan::sheet_w;
	float h = plan::sheet_h;
	float k = plan::k;
	s.appendf("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
	s.appendf("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%.2fmm\" height=\"%.2fmm\" viewBox=\"0 0 %.4f %.4f\" font-family=\"Helvetica, Arial, sans-serif\">\n", w / k, h / k, w, h);
	s.appendf("<rect width=\"%.4f\" height=\"%.4f\" fill=\"#ffffff\"/>\n", w, h);
	int level = -2;
	foreach (&p : plan::prims)
	{
		if (p.level != level)
		{
			if (level != -2) s.append("</g>\n");
			level = p.level;
			s.appendf("<g id=\"%s\">\n", level < 0 ? "sheet" : string::tformat("level-%d", level));
		}
		switch (p.kind)
		{
			case FILL:
				s.append("<path d=\"");
				path(&s, plan::prim_pts(p), true);
				s.appendf("\" fill=\"%s\"/>\n", hex(p.col));
			case LINE:
				s.append("<path d=\"");
				path(&s, plan::prim_pts(p), p.closed);
				s.appendf("\" fill=\"none\" stroke=\"%s\" stroke-width=\"%.4f\" stroke-linecap=\"round\" stroke-linejoin=\"round\"", hex(p.col), p.w);
				if (p.dash) s.appendf(" stroke-dasharray=\"%.4f %.4f\"", 1.2f * k, 0.8f * k);
				s.append("/>\n");
			case TEXT:
				s.appendf("<text x=\"%.4f\" y=\"%.4f\" font-size=\"%.4f\" fill=\"%s\" text-anchor=\"%s\" dominant-baseline=\"central\"",
					p.x, p.y, p.size, hex(p.col), p.left ? "start" : "middle");
				if (p.bold) s.append(" font-weight=\"bold\"");
				if (p.ang != 0) s.appendf(" transform=\"rotate(%.2f %.4f %.4f)\"", p.ang, p.x, p.y);
				s.append(">");
				escape(&s, plan::prim_text(p));
				s.append("</text>\n");
		}
	}
	if (level != -2) s.append("</g>\n");
	s.append("</svg>\n");
	return sys::write_file(file, s.str_view());
}
