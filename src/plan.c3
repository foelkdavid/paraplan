module paraplan::plan;
import std::io, std::math, std::core::string, std::collections::list;
import raylib6::rl;
import bmu::txt;
import paraplan::model;

// The drawing sheet as a display list in sheet metres (x right, y down; 1 m of building = 1 unit). The screen,
// the SVG writer and the PNG export all draw this same list, so what you see is what gets exported.
// Line widths and text sizes are given in paper mm and converted with `k` (= scale / 1000 m per mm).

alias Color = rl::RLColor;
alias Vec = float[<2>];

enum Pk : char
{
	FILL,       // polygon: outline pts[p0..p0+pn], triangles tris[t0..t0+tn]
	LINE,       // polyline pts[p0..p0+pn], width w, dashed
	TEXT,       // centred at (x, y), height size; text[s0..s0+sn]
}

struct Prim
{
	Pk kind;
	Color col;
	bool dash;
	bool closed;
	bool bold;
	bool left;          // TEXT: left aligned at x (else centred)
	bool vert;          // TEXT: rotated 90° counter-clockwise
	int p0;
	int pn;
	int t0;
	int tn;
	int s0;
	int sn;
	float w;
	float x;
	float y;
	float size;
	int room;           // FILL of a room: index in model::rooms, else -1
	int level;          // index in model::levels, -1 = sheet
}

struct Options
{
	int scale;          // 50, 100, 200
	bool furniture;
	bool dims;
	bool labels;
	bool[model::MAX_LEVELS] level_on;
}

const Color PAPER = { 255, 255, 255, 255 };
const Color INK = { 34, 34, 34, 255 };
const Color WALL = { 40, 40, 40, 255 };
const Color FENCE = { 120, 120, 120, 255 };
const Color ROOM = { 246, 243, 236, 255 };
const Color FURN = { 150, 150, 150, 255 };
const Color FURN_FILL = { 236, 233, 226, 255 };
const Color SOFT = { 110, 110, 110, 255 };
const Color STAIR = { 70, 70, 70, 255 };

List{Vec} pts;
List{Vec} tris;
List{Prim} prims;
DString text;
float sheet_w, sheet_h;     // metres
float k;                    // metres per paper mm
Options opt;
int cur_level = -1;
float[<4>][model::MAX_LEVELS] level_box;   // sheet rect of each level's drawing (x, y, w, h), w = 0: not shown

// Pens in paper mm.
const float PEN_THIN = 0.13f;
const float PEN = 0.25f;
const float PEN_BOLD = 0.5f;

fn void init()
{
	pts.init(mem, 4096);
	tris.init(mem, 4096);
	prims.init(mem, 1024);
	text.init(mem, 4096);
}

fn void reset()
{
	pts.clear();
	tris.clear();
	prims.clear();
	text.clear();
}

fn Prim* add(Pk kind, Color col)
{
	prims.push({ .kind = kind, .col = col, .room = -1, .level = cur_level, .p0 = (int)pts.len(), .t0 = (int)tris.len(), .s0 = (int)text.len() });
	return prims.get_ref(prims.len() - 1);
}

fn void line(Vec[] p, float pen_mm, Color col, bool dash = false, bool closed = false)
{
	Prim* pr = add(LINE, col);
	foreach (v : p) pts.push(v);
	pr.pn = (int)p.len;
	pr.w = pen_mm * k;
	pr.dash = dash;
	pr.closed = closed;
}

fn void seg(Vec a, Vec b, float pen_mm, Color col, bool dash = false)
{
	Vec[2] p = { a, b };
	line(&p, pen_mm, col, dash);
}

fn Vec vec(float x, float y) => { x, y };

fn float cross(Vec o, Vec a, Vec b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

// Filled polygon (any simple polygon; ear clipping). Returns the prim.
fn Prim* fill(Vec[] p, Color col)
{
	Prim* pr = add(FILL, col);
	foreach (v : p) pts.push(v);
	pr.pn = (int)p.len;
	triangulate(p);
	pr.tn = (int)tris.len() - pr.t0;
	return pr;
}

fn void triangulate(Vec[] p) => @pool()
{
	sz n = p.len;
	if (n < 3) return;
	int[] idx = mem::talloc_array(int, n);
	float area = 0;
	for (sz i = 0; i < n; i++) area += p[i].x * p[(i + 1) % n].y - p[(i + 1) % n].x * p[i].y;
	for (sz i = 0; i < n; i++) idx[i] = area > 0 ? (int)i : (int)(n - 1 - i);   // make it positive (y down: clockwise on screen)
	sz m = n;
	sz guard = 0;
	sz i = 0;
	while (m > 3 && guard < n * n)
	{
		guard++;
		sz ia = (i + m - 1) % m;
		sz ib = i % m;
		sz ic = (i + 1) % m;
		Vec a = p[idx[ia]];
		Vec b = p[idx[ib]];
		Vec c = p[idx[ic]];
		bool ear = cross(a, b, c) > 1e-9f;
		if (ear)
		{
			for (sz j = 0; j < m && ear; j++)
			{
				if (j == ia || j == ib || j == ic) continue;
				Vec q = p[idx[j]];
				if (cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0) ear = false;
			}
		}
		if (ear)
		{
			tris.push(a);
			tris.push(b);
			tris.push(c);
			for (sz j = ib; j + 1 < m; j++) idx[j] = idx[j + 1];
			m--;
			continue;
		}
		i++;
	}
	if (m == 3)
	{
		tris.push(p[idx[0]]);
		tris.push(p[idx[1]]);
		tris.push(p[idx[2]]);
	}
}

fn void label(String s, float x, float y, float size_mm, Color col = INK, bool bold = false)
{
	Prim* pr = add(TEXT, col);
	text.append(s);
	pr.sn = (int)text.len() - pr.s0;
	pr.x = x;
	pr.y = y;
	pr.size = size_mm * k;
	pr.bold = bold;
}

fn String prim_text(Prim* p) => text.str_view()[p.s0:p.sn];
fn Vec[] prim_pts(Prim* p) => pts.array_view()[p.p0:p.pn];
fn Vec[] prim_tris(Prim* p) => tris.array_view()[p.t0:p.tn];

// World (x, z) -> sheet, for the level being drawn.
float ox, oy;
fn Vec at(float x, float z) => { x + ox, -z + oy };
fn Vec atv(Vec w) => { w.x + ox, -w.y + oy };

fn Vec rot(float ang, float lx, float lz)
{
	// Unity: local x -> (cos, -sin), local z -> (sin, cos) in world x/z; sheet y = -z.
	float c = math::cos(ang);
	float s = math::sin(ang);
	return { lx * c + lz * s, -(-lx * s + lz * c) };
}

// Sheet-space corners of an item's footprint (centre + local half extents).
fn Vec item_pt(model::Item* it, float lx, float lz) => at(it.x, it.z) + rot(it.ang, lx, lz);

struct Box { float x0; float y0; float x1; float y1; }
fn void grow(Box* b, Vec p)
{
	b.x0 = math::min(b.x0, p.x);
	b.y0 = math::min(b.y0, p.y);
	b.x1 = math::max(b.x1, p.x);
	b.y1 = math::max(b.y1, p.y);
}

// Building extent of one level in world coords mapped with y = -z (wall faces included).
fn Box level_extent(int layer)
{
	Box b = { 1e9, 1e9, -1e9, -1e9 };
	foreach (&w : model::walls)
	{
		if (w.layer != layer || w.fence) continue;   // garden fences would stretch the sheet to the whole lot
		float h = w.thick * 0.5f;
		Vec a = { model::nodes[w.a].x, -model::nodes[w.a].z };
		Vec c = { model::nodes[w.b].x, -model::nodes[w.b].z };
		grow(&b, a - { h, h });
		grow(&b, a + { h, h });
		grow(&b, c - { h, h });
		grow(&b, c + { h, h });
		if (w.curved)
		{
			for (int i = 1; i < model::CURVE_STEPS; i++)
			{
				Vec q = model::bez({ model::nodes[w.a].x, model::nodes[w.a].z }, { w.cx, w.cz }, { model::nodes[w.b].x, model::nodes[w.b].z }, (float)i / model::CURVE_STEPS);
				grow(&b, { q.x - h, -q.y - h });
				grow(&b, { q.x + h, -q.y + h });
			}
		}
	}
	foreach (&r : model::rooms)
	{
		if (r.layer != layer) continue;
		foreach (p : model::room_poly(r)) grow(&b, { p.x, -p.y });
	}
	return b;
}

fn bool in_box(Box b, Vec p) => p.x >= b.x0 - 0.3f && p.x <= b.x1 + 0.3f && p.y >= b.y0 - 0.3f && p.y <= b.y1 + 0.3f;

fn int node_degree(int node, int layer)
{
	int d;
	foreach (&w : model::walls) if (w.layer == layer && !w.fence && (w.a == node || w.b == node)) d++;
	return d;
}

// The whole sheet: title, then every chosen level side by side.
fn void build(Options o, String title, String subtitle) => @pool()
{
	opt = o;
	k = (float)o.scale / 1000;
	reset();
	cur_level = -1;
	float margin = 15 * k;
	float gap = 25 * k;
	float dim_room = o.dims ? 16 * k : 0;
	float head = 26 * k;
	float x = margin + dim_room;
	float y = margin + head + dim_room;
	float bottom = y;
	foreach (&b : level_box) *b = {};
	for (int li = 0; li < model::level_count; li++)
	{
		if (!o.level_on[li]) continue;
		int layer = model::levels[li];
		Box b = level_extent(layer);
		if (b.x1 < b.x0) continue;
		ox = x - b.x0;
		oy = y - b.y0;
		cur_level = li;
		level_box[li] = { x, y, b.x1 - b.x0, b.y1 - b.y0 };
		draw_level(layer, b);
		float h = b.y1 - b.y0;
		// level caption under the drawing (below the dimension line)
		float cy = y + h + dim_room + 9 * k;
		float total = 0;
		foreach (&r : model::rooms) if (r.layer == layer) total += r.area;
		label(model::level_name(layer), x + (b.x1 - b.x0) / 2, cy, 4.2f, INK, true);
		label(string::tformat("%.1f m²", total), x + (b.x1 - b.x0) / 2, cy + 6.5f * k, 3, SOFT);
		bottom = math::max(bottom, cy + 10 * k);
		x += b.x1 - b.x0 + gap + dim_room;
	}
	cur_level = -1;
	sheet_w = math::max(x - gap - dim_room + margin + dim_room, 180 * k);
	sheet_h = bottom + margin + 8 * k;
	// header: name left, scale + scale bar right
	float hx = margin;
	float hy = margin;
	Prim* t = add(TEXT, INK);
	text.append(title);
	t.sn = (int)text.len() - t.s0;
	t.size = 7 * k;
	t.bold = true;
	t.x = hx;
	t.y = hy + 3.5f * k;
	t.left = true;
	Prim* st = add(TEXT, SOFT);
	text.append(subtitle);
	st.sn = (int)text.len() - st.s0;
	st.size = 3.2f * k;
	st.x = hx;
	st.y = hy + 11 * k;
	st.left = true;
	scale_bar(sheet_w - margin, hy + 2 * k);
	seg({ margin, hy + 17 * k }, { sheet_w - margin, hy + 17 * k }, PEN_THIN, SOFT);
}

// 0..5 m bar (0..2 m at 1:50), right aligned at (rx, y).
fn void scale_bar(float rx, float y)
{
	float len = opt.scale <= 50 ? 2 : opt.scale >= 200 ? 10 : 5;
	float x0 = rx - len;
	float h = 1.6f * k;
	int steps = (int)len;
	for (int i = 0; i < steps; i++)
	{
		Vec[4] r = { { x0 + i, y + 4 * k }, { x0 + i + 1, y + 4 * k }, { x0 + i + 1, y + 4 * k + h }, { x0 + i, y + 4 * k + h } };
		if (i % 2 == 0) { fill(&r, INK); } else { line(&r, PEN_THIN, INK, false, true); }
	}
	label("0", x0, y + 4 * k + h + 3 * k, 2.6f, SOFT);
	label(string::tformat("%d m", steps), rx, y + 4 * k + h + 3 * k, 2.6f, SOFT);
	label(string::tformat("1:%d", opt.scale), rx - len / 2, y + 1 * k, 3.2f, INK, true);
}

fn void draw_level(int layer, Box b)
{
	// 1. rooms
	foreach (i, &r : model::rooms)
	{
		if (r.layer != layer) continue;
		@pool()
		{
			Vec[] poly = mem::talloc_array(Vec, r.pn);
			foreach (j, p : model::room_poly(r)) poly[j] = atv(p);
			Prim* pr = fill(poly, ROOM);
			pr.room = (int)i;
		};
	}
	// 2. furniture and stairs (under the walls)
	foreach (&it : model::items)
	{
		if (it.kind == STAIRS && (it.layer == layer || it.layer == layer - 1)) stairs(it, it.layer != layer);
		if (it.kind != FURNITURE || it.layer != layer || !opt.furniture || it.on != 2) continue;
		if (it.dx < 0.15f || it.dz < 0.15f) continue;
		Vec[4] r = { item_pt(it, -it.dx / 2, -it.dz / 2), item_pt(it, it.dx / 2, -it.dz / 2), item_pt(it, it.dx / 2, it.dz / 2), item_pt(it, -it.dx / 2, it.dz / 2) };
		fill(&r, FURN_FILL);
		line(&r, PEN_THIN, FURN, false, true);
	}
	// 3. walls
	foreach (&w : model::walls)
	{
		if (w.layer != layer) continue;
		if (w.fence)
		{
			// only fences at the building (railings, porches), not the lot's garden fence
			Vec fa = { model::nodes[w.a].x, -model::nodes[w.a].z };
			Vec fb = { model::nodes[w.b].x, -model::nodes[w.b].z };
			if (in_box(b, fa) && in_box(b, fb)) fence(w);
			continue;
		}
		wall(w);
	}
	// joints: fill the wedge between walls meeting at an angle
	foreach (ni, &n : model::nodes)
	{
		float t = 0;
		int deg = 0;
		foreach (&w : model::walls) if (w.layer == layer && !w.fence && (w.a == ni || w.b == ni)) { deg++; t = math::max(t, w.thick); }
		if (deg < 2) continue;
		Vec[12] c;
		for (int i = 0; i < 12; i++) c[i] = at(n.x, n.z) + vec(math::cos((float)i * (float)math::PI / 6), math::sin((float)i * (float)math::PI / 6)) * (t * 0.5f);
		fill(&c, WALL);
	}
	// 4. openings
	foreach (&it : model::items)
	{
		if (it.layer != layer || it.on != 1) continue;
		if (it.kind == DOOR || it.kind == WINDOW || it.kind == ARCH) opening(it, layer);
	}
	// 5. labels
	if (opt.labels)
	{
		foreach (&r : model::rooms)
		{
			if (r.layer != layer || r.area < 1.5f) continue;   // closets, porch slivers: no room for a label
			Vec c = label_point(r);
			float s = r.area < 4 ? 0.75f : 1;
			label(txt::view(&r.name), c.x, c.y - 2.2f * k * s, 3.4f * s, INK, true);
			label(string::tformat("%.1f m²", r.area), c.x, c.y + 2.6f * k * s, 2.8f * s, SOFT);
		}
	}
	// 6. overall dimensions
	if (opt.dims)
	{
		float x0 = b.x0 + ox;
		float x1 = b.x1 + ox;
		float y0 = b.y0 + oy;
		float y1 = b.y1 + oy;
		dimension({ x0, y1 }, { x1, y1 }, { 0, 1 }, 10 * k);
		dimension({ x1, y0 }, { x1, y1 }, { 1, 0 }, 10 * k);
	}
}

// Area-weighted centroid of the room outline; the game's average point if that falls outside.
fn Vec label_point(model::Room* r)
{
	Vec[] p = model::room_poly(r);
	float a = 0;
	Vec c = {};
	for (sz i = 0; i < p.len; i++)
	{
		Vec u = p[i];
		Vec v = p[(i + 1) % p.len];
		float f = u.x * v.y - v.x * u.y;
		a += f;
		c += (u + v) * f;
	}
	if (math::abs(a) > 1e-6f)
	{
		c /= 3 * a;
		if (model::inside(p, c)) return atv(c);
	}
	return at(r.ax, r.az);
}

// Thick wall as a filled band. Straight walls get t/2 more at ends that meet other walls (square corners).
fn void wall(model::Wall* w) => @pool()
{
	float h = w.thick * 0.5f;
	Vec a = at(model::nodes[w.a].x, model::nodes[w.a].z);
	Vec b = at(model::nodes[w.b].x, model::nodes[w.b].z);
	if (!w.curved)
	{
		Vec d = b - a;
		float len = d.length();
		if (len < 1e-5f) return;
		d /= len;
		if (node_degree(w.a, w.layer) > 1) a -= d * h;
		if (node_degree(w.b, w.layer) > 1) b += d * h;
		Vec n = { -d.y, d.x };
		Vec[4] q = { a + n * h, b + n * h, b - n * h, a - n * h };
		fill(&q, WALL);
		return;
	}
	Vec c = at(w.cx, w.cz);
	int steps = model::CURVE_STEPS;
	Vec[] left = mem::talloc_array(Vec, (sz)(steps * 2 + 2));
	for (int i = 0; i <= steps; i++)
	{
		float t = (float)i / steps;
		Vec p = model::bez(a, c, b, t);
		Vec tan = (c - a) * (2 * (1 - t)) + (b - c) * (2 * t);
		if (tan.length() < 1e-6f) tan = b - a;
		tan = tan.normalize();
		Vec n = { -tan.y, tan.x };
		left[i] = p + n * h;
		left[steps * 2 + 1 - i] = p - n * h;
	}
	// one quad per step keeps every piece convex
	for (int i = 0; i < steps; i++)
	{
		Vec[4] q = { left[i], left[i + 1], left[steps * 2 - i], left[steps * 2 + 1 - i] };
		fill(&q, WALL);
	}
}

fn void fence(model::Wall* w) => @pool()
{
	Vec a = at(model::nodes[w.a].x, model::nodes[w.a].z);
	Vec b = at(model::nodes[w.b].x, model::nodes[w.b].z);
	if (!w.curved) { seg(a, b, PEN, FENCE); return; }
	Vec c = at(w.cx, w.cz);
	Vec[model::CURVE_STEPS + 1] p;
	for (int i = 0; i <= model::CURVE_STEPS; i++) p[i] = model::bez(a, c, b, (float)i / model::CURVE_STEPS);
	line(&p, PEN, FENCE);
}

// Thickness of the wall nearest to the item on its level (openings sit in walls).
fn float host_thickness(model::Item* it, int layer)
{
	float best = 1e9;
	float t = 0.2f;
	Vec p = { it.x, it.z };
	foreach (&w : model::walls)
	{
		if (w.layer != layer || w.fence) continue;
		Vec a = { model::nodes[w.a].x, model::nodes[w.a].z };
		Vec b = { model::nodes[w.b].x, model::nodes[w.b].z };
		Vec d = b - a;
		float l2 = d.dot(d);
		float u = l2 > 0 ? math::clamp((p - a).dot(d) / l2, 0.0f, 1.0f) : 0;
		float dist = (a + d * u - p).length();
		if (dist < best) { best = dist; t = w.thick; }
	}
	return t;
}

// Door / window / arch: clear the wall, then the symbol.
fn void opening(model::Item* it, int layer)
{
	float t = host_thickness(it, layer);
	float w = it.dx;
	float hw = w / 2;
	float ht = t / 2 + 0.01f;
	Vec[4] gap = { item_pt(it, -hw, -ht), item_pt(it, hw, -ht), item_pt(it, hw, ht), item_pt(it, -hw, ht) };
	fill(&gap, PAPER);
	// jambs
	seg(item_pt(it, -hw, -ht), item_pt(it, -hw, ht), PEN, INK);
	seg(item_pt(it, hw, -ht), item_pt(it, hw, ht), PEN, INK);
	switch (it.kind)
	{
		case WINDOW:
			seg(item_pt(it, -hw, -ht), item_pt(it, hw, -ht), PEN_THIN, INK);
			seg(item_pt(it, -hw, ht), item_pt(it, hw, ht), PEN_THIN, INK);
			seg(item_pt(it, -hw, 0), item_pt(it, hw, 0), PEN, INK);
		case ARCH:
			seg(item_pt(it, -hw, -ht), item_pt(it, hw, -ht), PEN_THIN, SOFT, true);
			seg(item_pt(it, -hw, ht), item_pt(it, hw, ht), PEN_THIN, SOFT, true);
		case DOOR:
			bool dbl = txt::icontains(txt::view(&it.name), "double");
			if (dbl)
			{
				door_leaf(it, -hw, hw, ht);
				door_leaf(it, hw, hw, ht);
			}
			else
			{
				door_leaf(it, it.flipped ? hw : -hw, w, ht);
			}
		default:
	}
}

// Leaf hinged at local x = hinge on the +z face, swinging out to +z, radius r; quarter arc back to the wall.
fn void door_leaf(model::Item* it, float hinge, float r, float ht)
{
	float dir = hinge < 0 ? 1 : -1;      // the closed leaf points from the hinge across the opening
	seg(item_pt(it, hinge, ht), item_pt(it, hinge, ht + r), PEN, INK);
	Vec[17] arc;
	for (int i = 0; i <= 16; i++)
	{
		float a = (float)i / 16 * (float)math::PI / 2;
		arc[i] = item_pt(it, hinge + dir * r * math::sin(a), ht + r * math::cos(a));
	}
	line(&arc, PEN_THIN, INK);
}

// Stair: outline, treads, walking line with an arrow (up = local +z). `above`: seen from the level above (dashed).
fn void stairs(model::Item* it, bool above)
{
	float hw = it.dx / 2;
	float hl = it.dz / 2;
	Vec[4] r = { item_pt(it, -hw, -hl), item_pt(it, hw, -hl), item_pt(it, hw, hl), item_pt(it, -hw, hl) };
	if (!above) fill(&r, PAPER);
	line(&r, PEN, STAIR, above, true);
	int n = math::max((int)(it.dz / 0.26f + 0.5f), 2);
	for (int i = 1; i < n; i++)
	{
		float z = -hl + it.dz * (float)i / n;
		seg(item_pt(it, -hw, z), item_pt(it, hw, z), PEN_THIN, STAIR, above);
	}
	if (above) return;
	seg(item_pt(it, 0, -hl + 0.15f), item_pt(it, 0, hl - 0.1f), PEN_THIN, STAIR);
	float ah = math::min(0.25f, hw * 0.6f);
	Vec[3] tip = { item_pt(it, 0, hl - 0.1f), item_pt(it, -ah * 0.6f, hl - 0.1f - ah), item_pt(it, ah * 0.6f, hl - 0.1f - ah) };
	fill(&tip, STAIR);
	Vec[12] dot;
	for (int i = 0; i < 12; i++) dot[i] = item_pt(it, 0, -hl + 0.15f) + vec(math::cos((float)i * (float)math::PI / 6), math::sin((float)i * (float)math::PI / 6)) * 0.05f;
	fill(&dot, STAIR);
}

// Dimension between a and b, drawn `off` away along `side` (unit), with extension lines, ticks and the length.
fn void dimension(Vec a, Vec b, Vec side, float off)
{
	Vec a2 = a + side * off;
	Vec b2 = b + side * off;
	seg(a + side * (2 * k), a2 + side * (1.5f * k), PEN_THIN, SOFT);
	seg(b + side * (2 * k), b2 + side * (1.5f * k), PEN_THIN, SOFT);
	seg(a2, b2, PEN_THIN, INK);
	Vec d = (b2 - a2).normalize();
	Vec tick = (d + side) * (1.2f * k);
	seg(a2 - tick, a2 + tick, PEN, INK);
	seg(b2 - tick, b2 + tick, PEN, INK);
	Vec m = (a2 + b2) / 2 - side * (2.4f * k);
	float len = (b - a).length();
	Prim* p = add(TEXT, INK);
	text.append(string::tformat("%.2f", len));
	p.sn = (int)text.len() - p.s0;
	p.x = m.x;
	p.y = m.y;
	p.size = 2.8f * k;
	p.vert = side.x != 0;
	if (p.vert) { p.x = a2.x + 2.4f * k; p.y = (a2.y + b2.y) / 2; }
}
