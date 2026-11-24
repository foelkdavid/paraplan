module paraplan;
import std::io, std::math, std::core::string, std::collections::list, std::thread;
import raylib6::rl;
import bmu::ui, bmu::txt, bmu::sys, bmu::picker;
import paraplan::model, paraplan::plan, paraplan::svg;

// paraplan: Paralives save -> real floor plans (SVG at true scale, PNG). Built on bmu.
// Run: c3c build && ./build/paraplan [save.saved | lot.lot]      Screenshot: ./build/paraplan --shot out.png

const String VERSION = "0.1.0";
const int ID_ROOM = 1;
const int ID_SCALE = 2;
const int PICK_SAVE = 1;
const int PICK_EXPORT = 2;
const float SIDE_W = 310;
const float TOP_H = 56;
const float STATUS_H = 26;

struct Settings
{
	float ui_scale;
	char[1024] export_dir;
	char[1024] last;
	int scale_sel;          // 0 1:50, 1 1:100, 2 1:200
	bool furniture;
	bool dims;
	bool labels;
}
Settings settings = { .scale_sel = 1, .furniture = true, .dims = true, .labels = true };
const int[3] SCALES = { 50, 100, 200 };
String[3] scale_names = { "1:50", "1:100", "1:200" };

struct RoomName
{
	long lot;
	long room;
	char[64] name;
}
List{RoomName} room_names;

bool[model::MAX_LEVELS] level_on;
int sel_room = -1;
char[64] room_buf;
float side_scroll;
bool help_open;
int help_tab;
float help_scroll;

// view: sheet metres -> logical px
float zoom = 40;
plan::Vec cam;
bool dragging;
plan::Vec press_at;
bool pressed;
bool png_pending;

ui::Shortcut[*] help_rows = {
	{ "PLAN", "", true },
	{ "Mouse wheel", "Zoom at the pointer", false },
	{ "Drag", "Move the sheet", false },
	{ "Click a room", "Select it (rename in the sidebar)", false },
	{ "F / Home", "Fit the sheet", false },
	{ "Up / Down", "Previous / next building", false },
	{ "FILES", "", true },
	{ "Ctrl + O", "Open a save folder", false },
	{ "Ctrl + E", "Export SVG (true scale)", false },
	{ "Ctrl + P", "Export PNG (300 dpi)", false },
	{ "WINDOW", "", true },
	{ "Ctrl + Shift + / - / 0", "UI zoom", false },
	{ "Ctrl + K", "Open / close this dialog", false },
};

fn String config_dir()
{
	String x = sys::env("XDG_CONFIG_HOME");
	return x.len ? txt::join(x, "paraplan") : txt::join(sys::home(), ".config/paraplan");
}

bool batch;     // --export: never write settings

fn void settings_save() => @pool()
{
	if (batch) return;
	DString s;
	s.tinit();
	s.appendf("ui_scale=%.2f\n", settings.ui_scale);
	s.appendf("export_dir=%s\n", txt::view(&settings.export_dir));
	s.appendf("last=%s\n", txt::view(&settings.last));
	s.appendf("scale=%d\n", settings.scale_sel);
	s.appendf("furniture=%d\ndims=%d\nlabels=%d\n", settings.furniture ? 1 : 0, settings.dims ? 1 : 0, settings.labels ? 1 : 0);
	sys::mkdirs(config_dir());
	if (!sys::write_file(txt::join(config_dir(), "settings.ini"), s.str_view())) ui::toast("Could not save settings", ui::RED);
}

fn void settings_load() => @pool()
{
	String? data = sys::read_temp(txt::join(config_dir(), "settings.ini"));
	if (try data)
	{
		foreach (line : data.tsplit("\n"))
		{
			sz? eq = line.index_of_char('=');
			if (catch eq) continue;
			String key = line[:(sz)eq].trim();
			String val = line[(sz)eq + 1..].trim();
			switch (key)
			{
				case "ui_scale": settings.ui_scale = (float)val.to_double() ?? 0;
				case "export_dir": txt::set(&settings.export_dir, val);
				case "last": txt::set(&settings.last, val);
				case "scale": settings.scale_sel = math::clamp(val.to_int() ?? 1, 0, 2);
				case "furniture": settings.furniture = val == "1";
				case "dims": settings.dims = val == "1";
				case "labels": settings.labels = val == "1";
			}
		}
	}
	if (txt::empty(&settings.export_dir))
	{
		String docs = txt::join(sys::home(), "Documents");
		txt::set(&settings.export_dir, sys::is_dir(docs) ? docs : sys::home());
	}
	String? rn = sys::read_temp(txt::join(config_dir(), "rooms.ini"));
	if (catch rn) return;
	foreach (line : rn.tsplit("\n"))
	{
		// <lot guid>:<room id>=<name>
		sz? eq = line.index_of_char('=');
		sz? colon = line.index_of_char(':');
		if (catch eq) continue;
		if (catch colon) continue;
		if (colon > eq) continue;
		RoomName r = { .lot = line[:(sz)colon].to_long() ?? 0, .room = line[(sz)colon + 1:(sz)(eq - colon - 1)].to_long() ?? 0 };
		txt::set(&r.name, line[(sz)eq + 1..].trim());
		room_names.push(r);
	}
}

fn void rooms_save() => @pool()
{
	DString s;
	s.tinit();
	foreach (&r : room_names) if (!txt::empty(&r.name)) s.appendf("%d:%d=%s\n", r.lot, r.room, txt::view(&r.name));
	sys::mkdirs(config_dir());
	if (!sys::write_file(txt::join(config_dir(), "rooms.ini"), s.str_view())) ui::toast("Could not save room names", ui::RED);
}

fn long cur_lot_guid() => model::cur_lot >= 0 ? model::lots[model::cur_lot].guid : 0;

fn void apply_room_names()
{
	long g = cur_lot_guid();
	foreach (&r : model::rooms)
	{
		txt::set(&r.name, txt::view(&r.auto_name));
		foreach (&n : room_names) if (n.lot == g && n.room == r.id && !txt::empty(&n.name)) txt::set(&r.name, txt::view(&n.name));
	}
}

fn void set_room_name(int ri, String name)
{
	long g = cur_lot_guid();
	model::Room* r = model::rooms.get_ref(ri);
	foreach (&n : room_names)
	{
		if (n.lot == g && n.room == r.id) { txt::set(&n.name, name); apply_room_names(); rooms_save(); return; }
	}
	RoomName n = { .lot = g, .room = r.id };
	txt::set(&n.name, name);
	room_names.push(n);
	apply_room_names();
	rooms_save();
}

fn void rebuild() => @pool()
{
	if (model::cur_lot < 0) { plan::reset(); plan::sheet_w = 0; return; }
	plan::Options o = { .scale = SCALES[settings.scale_sel], .furniture = settings.furniture, .dims = settings.dims, .labels = settings.labels };
	o.level_on = level_on;
	model::Lot* l = &model::lots[model::cur_lot];
	float total = 0;
	foreach (&r : model::rooms) if (level_index(r.layer) >= 0 && level_on[level_index(r.layer)]) total += r.area;
	String sub = string::tformat("Floor plan  ·  %s  ·  %.1f m² floor area  ·  paraplan", txt::view(&model::save_name), total);
	plan::build(o, txt::view(&l.name), sub);
}

fn int level_index(int layer)
{
	for (int i = 0; i < model::level_count; i++) if (model::levels[i] == layer) return i;
	return -1;
}

fn void select_lot(int i)
{
	if (i < 0 || i >= model::lot_count) return;
	sel_room = -1;
	ui::unfocus();
	if (!model::load_lot(i)) { ui::toast(txt::view(&model::load_error), ui::RED); }
	level_on = {};
	for (int k = 0; k < model::level_count; k++) level_on[k] = true;
	apply_room_names();
	rebuild();
	fit();
}

fn void open_path(String p)
{
	if (!model::open(p))
	{
		ui::toast(string::tformat("%s: %s", txt::basename(p), txt::view(&model::load_error)), ui::RED);
		return;
	}
	txt::set(&settings.last, txt::view(&model::save_path));
	settings_save();
	select_lot(0);
}

Rect canvas_rect;

fn void fit()
{
	Rect c = canvas_rect;
	if (plan::sheet_w <= 0 || c.width <= 0) return;
	zoom = math::min((c.width - 40) / plan::sheet_w, (c.height - 40) / plan::sheet_h);
	cam = { plan::sheet_w / 2 - c.width / 2 / zoom, plan::sheet_h / 2 - c.height / 2 / zoom };
}

fn void main(String[] args)
{
	model::init();
	plan::init();
	room_names.init(mem);
	settings_load();
	model::discover();
	ui::open("paraplan", 1400, 860, 900, 560, settings.ui_scale);
	defer ui::close();
	ui::zoom_shift_only = true;
	ui::app_args(args);
	String arg;
	String export_to;
	for (sz i = 1; i < args.len; i++)
	{
		if (args[i] == "--export" && i + 1 < args.len) { export_to = args[++i]; continue; }
		if (args[i].starts_with("--")) { i++; continue; }
		arg = args[i];
	}
	batch = export_to.len > 0;
	canvas_rect = { SIDE_W, TOP_H, ui::sw() - SIDE_W, ui::sh() - TOP_H - STATUS_H };
	if (arg.len) { open_path(arg); }
	else if (!txt::empty(&settings.last) && sys::exists(txt::view(&settings.last))) { open_path(txt::view(&settings.last)); }
	else if (model::save_count > 0) { open_path(txt::view(&model::saves[0].path)); }
	if (export_to.len)
	{
		// Batch: every building of the save as SVG + PNG into export_to, then quit (settings untouched).
		txt::set(&settings.export_dir, export_to);
		for (int i = 0; i < model::lot_count; i++)
		{
			select_lot(i);
			export_svg();
			export_png();
			png_poll(true);
		}
		return;
	}
	while (ui::running())
	{
		frame();
		if (png_pending) { png_pending = false; export_png(); }
		if (ui::close_requested) { png_poll(true); ui::quit = true; }
	}
	png_poll(true);
}

fn void frame() => @pool()
{
	ui::frame_begin(help_open || picker::open);
	png_poll();
	if (ui::zoom_changed) { settings.ui_scale = ui::scale; settings_save(); }
	float w = ui::sw();
	float h = ui::sh();
	Rect prev = canvas_rect;
	canvas_rect = { SIDE_W, TOP_H, w - SIDE_W, h - TOP_H - STATUS_H };
	if (prev.width != canvas_rect.width || prev.height != canvas_rect.height)
	{
		// keep the centre when the window resizes
		cam += plan::vec(prev.width - canvas_rect.width, prev.height - canvas_rect.height) / (2 * zoom);
	}
	shortcuts();
	canvas();
	sidebar();
	top_bar(w);
	status_bar(w, h);

	ui::layer = 1;
	if (help_open) help_dialog();
	if (picker::open) picker::draw();
	ui::layer = 0;

	int why;
	String path;
	if (picker::take(&why, &path))
	{
		if (why == PICK_SAVE) open_path(path);
		if (why == PICK_EXPORT) { txt::set(&settings.export_dir, path); settings_save(); }
	}
	handle_drop();
	ui::frame_end();
}

fn void shortcuts()
{
	if (ui::ctrl_down() && ui::letter('k') && (ui::top == 0 || help_open)) { help_open = !help_open; help_tab = 0; return; }
	if (ui::top != 0) return;
	if (ui::ctrl_down() && ui::letter('o')) { pick_save(); return; }
	if (ui::ctrl_down() && ui::letter('e')) { export_svg(); return; }
	if (ui::ctrl_down() && ui::letter('p')) { png_pending = model::cur_lot >= 0; return; }
	if (ui::focus >= 0) return;
	if (ui::letter('f') || rl::is_key_pressed(rl::RLKeyboardKey.HOME)) fit();
	if (ui::repeat(rl::RLKeyboardKey.DOWN) && model::cur_lot + 1 < model::lot_count) select_lot(model::cur_lot + 1);
	if (ui::repeat(rl::RLKeyboardKey.UP) && model::cur_lot > 0) select_lot(model::cur_lot - 1);
	if (rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE)) sel_room = -1;
}

fn void pick_save() => @pool()
{
	String start = txt::view(&model::save_path);
	start = start.len ? txt::dirname(start) : model::save_count ? txt::dirname(txt::view(&model::saves[0].path)) : sys::home();
	picker::start(PICK_SAVE, DIR, "Open a Paralives save (.saved folder)", start);
}

fn void handle_drop()
{
	if (!rl::is_file_dropped()) return;
	rl::RLFilePathList files = rl::load_dropped_files();
	if (files.count > 0) open_path(files.paths[0].str_view());
	rl::unload_dropped_files(files);
}

// --- top / status ------------------------------------------------------------

fn void top_bar(float w)
{
	ui::panel({ 0, 0, w, TOP_H }, ui::BG_HARD);
	ui::hline(0, TOP_H - 1, w, ui::BG1);
	ui::text(ui::I_GRID, 18, 17, 20, ui::YELLOW);
	ui::text("paraplan", 48, 14, 22, ui::FG);
	float tx = 48 + ui::text_w("paraplan", 22) + 18;
	if (model::cur_lot >= 0)
	{
		String s = string::tformat("%s  ·  %s", txt::view(&model::save_name), txt::view(&model::lots[model::cur_lot].name));
		ui::text_fit(s, tx, 19, w - tx - 520, 15, ui::FG4);
	}
	if (ui::icon_button({ w - 52, 9, 38, 38 }, ui::I_GEAR, ui::FG4, "Settings (Ctrl+K)")) { help_open = true; help_tab = 0; }
	bool can = model::cur_lot >= 0;
	if (ui::button({ w - 172, 9, 112, 38 }, png.running ? "Saving…" : "PNG", NORMAL, ui::I_IMAGE, can && !png.running)) png_pending = true;
	if (ui::button({ w - 292, 9, 112, 38 }, "SVG", PRIMARY, ui::I_DOWNLOAD, can)) export_svg();
	if (ui::button({ w - 432, 9, 132, 38 }, "Open…", NORMAL, ui::I_FOLDER_OPEN)) pick_save();
}

fn void status_bar(float w, float h)
{
	ui::panel({ 0, h - STATUS_H, w, STATUS_H }, ui::BG_HARD);
	String s = "Drop a .saved folder or a .lot file  ·  wheel: zoom  ·  drag: move  ·  F: fit  ·  Ctrl+K: help";
	if (ui::hover(canvas_rect) && plan::sheet_w > 0)
	{

		s = string::tformat("%s  ·  sheet 1:%d", s, SCALES[settings.scale_sel]);

	}
	ui::text_fit(s, 14, h - 20, w - 28, 13, ui::GRAY);
}

// --- sidebar -----------------------------------------------------------------

fn void heading(String s, float x, float y) => ui::text(s, x, y, 12, ui::GRAY);

fn bool row(Rect r, String title, String detail, bool on, String icon)
{
	bool hov = ui::hover(r);
	if (on) { ui::panel(r, ui::BG2, 4); } else if (hov) { ui::panel(r, ui::BG1, 4); }
	ui::text(icon, r.x + 10, r.y + (r.height - 16) / 2, 15, on ? ui::YELLOW : ui::FG4);
	if (detail.len)
	{
		ui::text_fit(title, r.x + 34, r.y + 5, r.width - 44, 15, on ? ui::FG : ui::FG4);
		ui::text_fit(detail, r.x + 34, r.y + 24, r.width - 44, 12, ui::GRAY);
	}
	else
	{
		ui::text_fit(title, r.x + 34, r.y + (r.height - 16) / 2, r.width - 44, 15, on ? ui::FG : ui::FG4);
	}
	return ui::clicked(r);
}

fn void sidebar()
{
	float h = ui::sh();
	Rect area = { 0, TOP_H, SIDE_W, h - TOP_H - STATUS_H };
	ui::panel(area, ui::BG_HARD);
	ui::panel({ SIDE_W - 1, TOP_H, 1, area.height }, ui::BG1);
	float x = 14;
	float iw = SIDE_W - 28;
	float y0 = TOP_H + 14 - side_scroll;
	float y = y0;
	ui::begin_clip(area);

	if (model::save_count > 0)
	{
		heading("SAVES", x, y);
		y += 22;
		for (int i = 0; i < model::save_count; i++)
		{
			bool on = txt::view(&model::saves[i].path) == txt::view(&model::save_path);
			if (row({ x, y, iw, 32 }, txt::view(&model::saves[i].name), "", on, ui::I_FOLDER) && !on) open_path(txt::view(&model::saves[i].path));
			y += 34;
		}
		y += 12;
	}

	heading("BUILDINGS", x, y);
	y += 22;
	if (model::lot_count == 0)
	{
		ui::text(model::save_count ? "No buildings in this save." : "No Paralives saves found. Open… one.", x, y, 13, ui::GRAY);
		y += 24;
	}
	for (int i = 0; i < model::lot_count; i++)
	{
		model::Lot* l = &model::lots[i];
		String d = l.premade ? "premade" : "built in this save";
		if (l.street) d = string::tformat("No. %d  ·  %s", l.street, d);
		if (row({ x, y, iw, 44 }, txt::view(&l.name), d, i == model::cur_lot, ui::I_HOME) && i != model::cur_lot) select_lot(i);
		y += 46;
	}
	y += 12;

	if (model::cur_lot >= 0)
	{
		heading("LEVELS", x, y);
		y += 22;
		for (int i = 0; i < model::level_count; i++)
		{
			int nr;
			foreach (&r : model::rooms) if (r.layer == model::levels[i]) nr++;
			String s = string::tformat("%s  (%d room%s)", model::level_name(model::levels[i]), nr, nr == 1 ? "" : "s");
			if (ui::checkbox(x, y, s, &level_on[i])) { rebuild(); fit(); }
			y += 30;
		}
		y += 12;

		if (sel_room >= 0)
		{
			heading("ROOM", x, y);
			y += 22;
			bool enter;
			if (ui::input(ID_ROOM, { x, y, iw - 92, 36 }, &room_buf, txt::view(&model::rooms[sel_room].auto_name), &enter))
			{
				set_room_name(sel_room, txt::view(&room_buf));
				rebuild();
			}
			if (ui::button({ x + iw - 84, y, 84, 36 }, "Auto", GHOST, ui::I_UNDO))
			{
				room_buf[0] = 0;
				set_room_name(sel_room, "");
				rebuild();
			}
			y += 42;
			ui::text(string::tformat("%.1f m²  ·  %s", model::rooms[sel_room].area, model::level_name(model::rooms[sel_room].layer)), x, y, 13, ui::GRAY);
			y += 30;
		}

		heading("PLAN", x, y);
		y += 22;
		ui::text("Scale", x, y + 9, 15, ui::FG4);
		if (ui::dropdown(ID_SCALE, { x + 90, y, iw - 90, 36 }, &scale_names, &settings.scale_sel)) { settings_save(); rebuild(); fit(); }
		y += 46;
		if (ui::checkbox(x, y, "Room names and areas", &settings.labels)) { settings_save(); rebuild(); }
		y += 30;
		if (ui::checkbox(x, y, "Dimensions", &settings.dims)) { settings_save(); rebuild(); fit(); }
		y += 30;
		if (ui::checkbox(x, y, "Furniture", &settings.furniture)) { settings_save(); rebuild(); }
		y += 42;

		heading("EXPORT TO", x, y);
		y += 22;
		ui::text_tail(txt::view(&settings.export_dir), x, y + 9, iw - 48, 13, ui::FG4);
		if (ui::icon_button({ x + iw - 38, y, 38, 36 }, ui::I_FOLDER_OPEN, ui::FG4, "Choose the export folder"))
		{
			picker::start(PICK_EXPORT, DIR, "Export floor plans to…", txt::view(&settings.export_dir));
		}
		y += 44;
		ui::text("SVG prints at true scale (100 %).", x, y, 12, ui::GRAY);
		y += 20;
	}
	ui::end_clip();
	float content = y + side_scroll - TOP_H;
	side_scroll = ui::scroll_wheel(area, side_scroll, content);
	ui::scrollbar(area, side_scroll, content);
}

// --- canvas ------------------------------------------------------------------

fn plan::Vec to_screen(plan::Vec p) => { canvas_rect.x + (p.x - cam.x) * zoom, canvas_rect.y + (p.y - cam.y) * zoom };
fn plan::Vec to_sheet(rl::RLVector2 m) => { (m.x - canvas_rect.x) / zoom + cam.x, (m.y - canvas_rect.y) / zoom + cam.y };

fn void canvas()
{
	Rect c = canvas_rect;
	ui::panel(c, { 50, 48, 46, 255 });
	if (plan::sheet_w <= 0)
	{
		String s = model::lot_count ? "Pick a building." : "Open a Paralives save (Ctrl+O) or drop a .saved folder here.";
		ui::text(s, c.x + (c.width - ui::text_w(s, 16)) / 2, c.y + c.height / 2 - 10, 16, ui::FG4);
		return;
	}
	// input
	rl::RLVector2 m = rl::get_mouse_position();
	bool over = ui::hover(c);
	if (over)
	{
		float wheel = rl::get_mouse_wheel_move();
		if (wheel != 0)
		{
			plan::Vec before = to_sheet(m);
			zoom = math::clamp(zoom * math::pow(1.15f, wheel), 2.0f, 2000.0f);
			plan::Vec after = to_sheet(m);
			cam += before - after;
		}
		if (rl::is_mouse_button_pressed(rl::RLMouseButton.LEFT) || rl::is_mouse_button_pressed(rl::RLMouseButton.MIDDLE))
		{
			pressed = true;
			dragging = false;
			press_at = { m.x, m.y };
			ui::consumed = true;
		}
	}
	if (pressed)
	{
		bool down = rl::is_mouse_button_down(rl::RLMouseButton.LEFT) || rl::is_mouse_button_down(rl::RLMouseButton.MIDDLE);
		if (down)
		{
			if ((plan::vec(m.x, m.y) - press_at).length() > 4) dragging = true;
			if (dragging)
			{
				rl::RLVector2 d = rl::get_mouse_delta();
				cam -= plan::vec(d.x, d.y) / (zoom * ui::scale);
				ui::cursor = rl::RLMouseCursor.RESIZE_ALL;
			}
		}
		else
		{
			if (!dragging) pick_room(to_sheet(m));
			pressed = false;
			dragging = false;
		}
	}

	ui::begin_clip(c);
	plan::Vec a = to_screen({ 0, 0 });
	ui::panel({ a.x + 4, a.y + 4, plan::sheet_w * zoom, plan::sheet_h * zoom }, { 30, 30, 30, 120 });
	ui::panel({ a.x, a.y, plan::sheet_w * zoom, plan::sheet_h * zoom }, plan::PAPER);
	draw_sheet({ canvas_rect.x, canvas_rect.y }, cam, zoom);
	if (sel_room >= 0)
	{
		foreach (&p : plan::prims)
		{
			if (p.kind != FILL || p.room != sel_room) continue;
			plan::Vec[] q = plan::prim_pts(p);
			for (sz i = 0; i < q.len; i++) rl::draw_line_ex(v(to_screen(q[i])), v(to_screen(q[(i + 1) % q.len])), 3, { 215, 153, 33, 255 });
		}
	}
	ui::end_clip();
}

fn rl::RLVector2 v(plan::Vec p) => { p.x, p.y };

fn void pick_room(plan::Vec p)
{
	sel_room = -1;
	ui::unfocus();
	foreach (&pr : plan::prims)
	{
		if (pr.kind != FILL || pr.room < 0) continue;
		if (model::inside(plan::prim_pts(pr), p)) sel_room = pr.room;   // later (upper) prims win
	}
	if (sel_room >= 0)
	{
		model::Room* r = model::rooms.get_ref(sel_room);
		txt::set(&room_buf, txt::view(&r.name) == txt::view(&r.auto_name) ? "" : txt::view(&r.name));
	}
}

// Text sizes snap to ~8 % steps so zooming bakes few font atlases.
fn float snap_size(float s)
{
	if (s <= 8) return math::round(s);
	float stepf = math::round(math::ln(s / 8) / math::ln(1.08f));
	return 8 * math::pow(1.08f, stepf);
}

// Draw the display list: sheet point p -> origin + (p - cam) * z (logical px).
fn void draw_sheet(plan::Vec origin, plan::Vec cam_at, float z) => @pool()
{
	float min_w = 1 / ui::px;
	foreach (&p : plan::prims)
	{
		switch (p.kind)
		{
			case FILL:
				plan::Vec[] t = plan::prim_tris(p);
				for (sz i = 0; i + 2 < t.len; i += 3)
				{
					plan::Vec a = origin + (t[i] - cam_at) * z;
					plan::Vec b = origin + (t[i + 1] - cam_at) * z;
					plan::Vec c = origin + (t[i + 2] - cam_at) * z;
					// raylib culls clockwise-on-screen triangles: order them
					if (plan::cross(a, b, c) < 0) { rl::draw_triangle(v(a), v(b), v(c), p.col); } else { rl::draw_triangle(v(a), v(c), v(b), p.col); }
				}
			case LINE:
				plan::Vec[] q = plan::prim_pts(p);
				float lw = math::max(p.w * z, min_w);
				sz n = p.closed ? q.len : q.len - 1;
				if (!p.dash)
				{
					for (sz i = 0; i < n; i++) rl::draw_line_ex(v(origin + (q[i] - cam_at) * z), v(origin + (q[(i + 1) % q.len] - cam_at) * z), lw, p.col);
					continue;
				}
				float dash = 1.2f * plan::k;
				float gap = 0.8f * plan::k;
				for (sz i = 0; i < n; i++)
				{
					plan::Vec s = q[i];
					plan::Vec e = q[(i + 1) % q.len];
					float len = (e - s).length();
					if (len <= 0) continue;
					plan::Vec d = (e - s) / len;
					for (float u = 0; u < len; u += dash + gap)
					{
						float u2 = math::min(u + dash, len);
						rl::draw_line_ex(v(origin + (s + d * u - cam_at) * z), v(origin + (s + d * u2 - cam_at) * z), lw, p.col);
					}
				}
			case TEXT:
				float size = snap_size(p.size * z);
				if (size < 5) continue;
				String s = plan::prim_text(p);
				plan::Vec at = origin + (plan::vec(p.x, p.y) - cam_at) * z;
				float tw = ui::text_w(s, size);
				if (p.vert)
				{
					rl::RLFont* f = ui::sized_font(size);
					rl::draw_text_pro(*f, s.zstr_tcopy(), v(at), { tw / 2, size / 2 }, -90, ui::text_size(size), 0, p.col);
					continue;
				}
				ui::text(s, p.left ? at.x : at.x - tw / 2, at.y - size / 2, size, p.col);
		}
	}
}

// --- export ------------------------------------------------------------------

// <export dir>/<save>_<lot> (temp: call inside the caller's @pool).
fn String export_base()
{
	char[128] a;
	char[128] b;
	txt::slug(&a, txt::view(&model::save_name), "save");
	txt::slug(&b, txt::view(&model::lots[model::cur_lot].name), "lot");
	return txt::join(txt::view(&settings.export_dir), string::tformat("%s_%s", txt::view(&a), txt::view(&b)));
}

fn void export_svg() => @pool()
{
	if (model::cur_lot < 0 || plan::prims.len() == 0) return;
	String f = string::tformat("%s.svg", export_base());
	if (!sys::mkdirs(txt::view(&settings.export_dir)) || !svg::write(f)) { ui::toast(string::tformat("Could not write %s", f), ui::RED); io::eprintfn("could not write %s", f); return; }
	ui::toast(string::tformat("Saved %s", txt::basename(f)), ui::GREEN);
	io::printfn("%s", f);
}

// PNG encoding (stb, ~1.5 s for a big sheet) runs on a worker thread; the UI polls `png_done` once per frame.
struct PngJob
{
	thread::Thread worker;
	thread::Mutex mutex;
	rl::RLImage img;
	char[1024] path;
	bool running;
	bool done;
	bool ok;
	int w, h;
}
PngJob png;

extern int stbi_write_png_compression_level @cname("stbi_write_png_compression_level");

fn int png_work(void* arg)
{
	rl::image_flip_vertical(&png.img);
	rl::image_format(&png.img, rl::RLPixelFormat.UNCOMPRESSED_R8G8B8);   // no alpha: smaller, faster
	bool ok = rl::export_image(png.img, txt::z(&png.path));
	rl::unload_image(png.img);
	png.mutex.lock();
	png.ok = ok;
	png.done = true;
	png.mutex.unlock();
	return 0;
}

// Once per frame (and before quitting): report a finished PNG. `wait` blocks until it is written.
fn void png_poll(bool wait = false) => @pool()
{
	if (!png.running) return;
	png.mutex.lock();
	bool done = png.done;
	png.mutex.unlock();
	if (!done && !wait) return;
	png.worker.join()!!;
	png.running = false;
	ui::hold_close = false;
	String f = txt::view(&png.path);
	if (!png.ok) { ui::toast(string::tformat("Could not write %s", f), ui::RED); io::eprintfn("could not write %s", f); return; }
	ui::toast(string::tformat("Saved %s (%d × %d)", txt::basename(f), png.w, png.h), ui::GREEN);
	io::printfn("%s", f);
}

// 300 dpi at the chosen paper scale, rendered at 2x and scaled down (smooth edges), at most 8000 px wide/high.
fn void export_png() => @pool()
{
	if (model::cur_lot < 0 || plan::sheet_w <= 0 || png.running) return;
	float ppm = 300.0f / 25.4f / plan::k;           // px per sheet metre
	float fit = math::min(8000 / (plan::sheet_w * ppm), 8000 / (plan::sheet_h * ppm));
	if (fit < 1) ppm *= fit;
	int w = (int)(plan::sheet_w * ppm + 0.5f);
	int h = (int)(plan::sheet_h * ppm + 0.5f);
	// Render at 2x, then let the GPU halve it (bilinear at exact 2x = a 2x2 box filter): smooth edges, cheap.
	int ss = w * 2 <= 16384 && h * 2 <= 16384 ? 2 : 1;
	rl::RLRenderTexture2D big = rl::load_render_texture(w * ss, h * ss);
	if (!big.id) { ui::toast("PNG: render texture failed", ui::RED); return; }
	rl::begin_texture_mode(big);
	rl::clear_background(plan::PAPER);
	rl::begin_mode2d({ .zoom = ui::px });
	draw_sheet({ 0, 0 }, { 0, 0 }, ppm * ss / ui::px);
	rl::end_mode2d();
	rl::end_texture_mode();
	rl::RLRenderTexture2D rt = big;
	if (ss > 1)
	{
		rt = rl::load_render_texture(w, h);
		if (!rt.id) { rl::unload_render_texture(big); ui::toast("PNG: render texture failed", ui::RED); return; }
		big.texture.set_filter(rl::RLTextureFilter.BILINEAR);
		rl::begin_texture_mode(rt);
		rl::draw_texture_pro(big.texture, { 0, 0, (float)(w * ss), -(float)(h * ss) }, { 0, 0, (float)w, (float)h }, { 0, 0 }, 0, rl::WHITE);
		rl::end_texture_mode();
		rl::unload_render_texture(big);
	}
	rl::RLImage img = rl::load_image_from_texture(rt.texture);
	rl::unload_render_texture(rt);
	String f = string::tformat("%s.png", export_base());
	if (!sys::mkdirs(txt::view(&settings.export_dir))) { rl::unload_image(img); ui::toast(string::tformat("Could not write %s", f), ui::RED); return; }
	png.img = img;
	png.w = w;
	png.h = h;
	png.done = false;
	txt::set(&png.path, f);
	if (!png.mutex.is_initialized()) png.mutex.init()!!;
	stbi_write_png_compression_level = 6;
	if (catch png.worker.create(&png_work, null))
	{
		png_work(null);   // no thread: write it here
		png.running = true;
		png_poll(true);
		return;
	}
	png.running = true;
	ui::hold_close = true;
	ui::toast("Saving PNG…", ui::AQUA);
}

// --- help --------------------------------------------------------------------

fn void help_dialog()
{
	Rect box = ui::dialog(640, 480);
	if (ui::dialog_header(box, ui::I_GEAR, "paraplan") || (ui::live() && rl::is_key_pressed(rl::RLKeyboardKey.ESCAPE))) help_open = false;
	float x = box.x + 16;
	float w = box.width - 32;
	if (ui::button({ x, box.y + 54, w / 2 - 4, 36 }, "Shortcuts", help_tab == 0 ? PRIMARY : NORMAL)) help_tab = 0;
	if (ui::button({ x + w / 2 + 4, box.y + 54, w / 2 - 4, 36 }, "About", help_tab == 1 ? PRIMARY : NORMAL))
	{
		help_tab = 1;
		ui::about_reset("paraplan", VERSION);
		ui::about_add("Game", txt::empty(&model::game_dir) ? "not found (no item names)" : txt::view(&model::game_dir));
		ui::about_add("Item names", string::tformat("%d", model::cat_count));
		ui::about_add("Config", config_dir());
	}
	Rect area = { x, box.y + 102, w, box.height - 118 };
	if (help_tab == 0) { help_scroll = ui::shortcut_table(area, &help_rows, help_scroll); }
	else { ui::about_draw(area); }
}
