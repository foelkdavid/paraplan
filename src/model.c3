module paraplan::model;
import std::io, std::math, std::core::string, std::collections::list, std::collections::map;
import std::collections::object, std::encoding::json;
import bmu::txt, bmu::sys;

// Paralives saves, read-only. A save is a folder `<name>.saved` with one `<guid>.town` folder; every lot that was
// built or visited is `<town>/<lotguid>.lot` (JSON). Lots the player never touched point at a premade lot of the
// game install (`lotperimeters` LotData.ProxyPremadeLotGUID -> Main.mod/PremadeLots/<guid>.lot). Geometry is in
// metres: x/z ground plane (y up, Unity), walls between nodes, `Layer` = storey. Wall thickness is in 0.1 m units.

const String SAVES_SUB = "steamapps/compatdata/1118520/pfx/drive_c/users/steamuser/AppData/LocalLow/Paralives/Paralives/MySavedGames.mod";
const String GAME_SUB = "steamapps/common/Paralives";
const MAX_LIBS = 16;
const MAX_SAVES = 64;
const MAX_LOTS = 256;
const MAX_LEVELS = 32;
const MAX_CATALOGUE = 8192;

struct PathBuf { char[1024] s; }

struct SaveRef
{
	char[1024] path;
	char[128] name;
}

struct Lot
{
	char[1024] path;      // the .lot file
	char[128] name;
	long guid;            // key for room names (lot GUID in the town, else the file's GUID)
	int street;           // street number, 0 = none
	bool premade;         // geometry comes from the game's premade lot
}

enum Kind : char
{
	OTHER,
	FURNITURE,
	DOOR,
	WINDOW,
	ARCH,
	STAIRS,
	ROOF,
}

struct Node { long id; float x; float z; }

struct Wall
{
	long id;
	int a;             // node indices
	int b;
	float cx;         // quadratic Bezier control point (absolute), when curved
	float cz;
	bool curved;
	bool fence;
	float thick;          // metres
	int layer;
	int placed_at;        // PlacedAtHeight: < 0 below the ground (basements)
}

struct Room
{
	long id;
	int layer;
	float area;           // m², as the game reports it (wall centre lines)
	int p0;           // outline in `room_pts` (x, z)
	int pn;
	float ax;         // the game's average position
	float az;
	char[64] auto_name;   // guessed from the furniture inside
	char[64] name;        // shown: user name or auto_name
}

struct Item
{
	long cat;
	float x;
	float y;
	float z;
	float ang;            // rotation about y, radians (Unity: local x -> (cos, -sin) in x/z)
	float dx;
	float dy;
	float dz;
	int layer;
	int on;               // PlacedOn.Type: 1 wall, 2 floor, 3 item, 0 ground
	bool flipped;
	Kind kind;
	char[48] name;
}

// discovery
PathBuf[MAX_LIBS] libs;
int lib_count;
char[1024] game_dir;
SaveRef[MAX_SAVES] saves;
int save_count;

// the open save
char[1024] save_path;
char[128] save_name;
Lot[MAX_LOTS] lots;
int lot_count;
char[256] load_error;

// the open lot
int cur_lot = -1;
List{Node} nodes;
List{Wall} walls;
List{Room} rooms;
List{float[<2>]} room_pts;
List{Item} items;
int[MAX_LEVELS] levels;
int level_count;
int ground = 0;       // index into levels of the ground floor

// item catalogue (game install Main.mod/Settings/Items.setting): GUID -> internal name like "DoorHalfLite2Panel"
struct CatName { long guid; char[48] name; }
CatName* catalogue;
int cat_count;
bool cat_tried;

// Heap lists (an uninitialised List would grow in temp memory).
fn void init()
{
	nodes.init(mem);
	walls.init(mem);
	rooms.init(mem);
	room_pts.init(mem, 1024);
	items.init(mem);
}

fn String lib(int i) => txt::view(&libs[i].s);

// Steam libraries -> saves and the game install. Cheap (a few stats + one directory listing per library).
fn void discover() => @pool()
{
	lib_count = 0;
	save_count = 0;
	game_dir[0] = 0;
	String home = sys::home();
	String[4] roots = {
		txt::join(home, ".local/share/Steam"),
		txt::join(home, ".steam/root"),
		txt::join(home, ".steam/steam"),
		txt::join(home, ".var/app/com.valvesoftware.Steam/data/Steam"),
	};
	foreach (r : roots)
	{
		if (!sys::is_dir(txt::join(r, "steamapps"))) continue;
		add_lib(r);
		String? vdf = sys::read_temp(txt::join(r, "steamapps/libraryfolders.vdf"));
		if (catch vdf) continue;
		sz pos = 0;
		while (try v = vdf_next(vdf, "path", &pos)) add_lib(v);
	}
	for (int i = 0; i < lib_count; i++)
	{
		String g = txt::join(lib(i), GAME_SUB);
		if (txt::empty(&game_dir) && sys::is_dir(txt::join(g, "Main.mod"))) txt::set(&game_dir, g);
		String dir = txt::join(lib(i), SAVES_SUB);
		sys::Entry[] ents = mem::talloc_array(sys::Entry, 256);
		int n = sys::list_dir(dir, ents, false);
		for (int k = 0; k < n && save_count < MAX_SAVES; k++)
		{
			String name = txt::view(&ents[k].name);
			if (!ents[k].dir || !txt::iends_with(name, ".saved")) continue;
			SaveRef* s = &saves[save_count++];
			txt::set(&s.path, txt::join(dir, name));
			txt::set(&s.name, name[:name.len - 6]);
		}
	}
}

fn void add_lib(String p)
{
	if (lib_count >= MAX_LIBS || !sys::is_dir(p)) return;
	char[1024] real;
	sys::realpath(&real, p);
	for (int i = 0; i < lib_count; i++) if (lib(i) == txt::view(&real)) return;
	txt::set(&libs[lib_count++].s, txt::view(&real));
}

fn String? vdf_next(String data, String key, sz* pos)
{
	String needle = string::tformat("\"%s\"", key);
	while (*pos < data.len)
	{
		sz? idx = data[*pos..].index_of(needle);
		if (catch idx) return NOT_FOUND~;
		sz i = *pos + (sz)idx + needle.len;
		*pos = i;
		while (i < data.len && (data[i] == ' ' || data[i] == '\t')) i++;
		if (i >= data.len || data[i] != '"') continue;
		i++;
		sz start = i;
		while (i < data.len && data[i] != '"') i++;
		*pos = i + 1;
		return data[start:i - start];
	}
	return NOT_FOUND~;
}

// JSON helpers: missing keys read as 0 / null.
fn Object* sub(Object* o, String k)
{
	if (o == null || !o.is_map()) return null;
	Object*? v = o.get(k);
	if (catch v) return null;
	return v;
}
fn float num(Object* o, String k)
{
	if (o == null || !o.is_map()) return 0;
	return (float)(o.get_float(k) ?? 0);
}
fn long lng(Object* o, String k)
{
	if (o == null || !o.is_map()) return 0;
	return o.get_long(k) ?? 0;
}
fn bool flag(Object* o, String k)
{
	if (o == null || !o.is_map()) return false;
	return o.get_bool(k) ?? false;
}
fn String str(Object* o, String k)
{
	if (o == null || !o.is_map()) return "";
	return o.get_string(k) ?? "";
}
fn sz count(Object* arr) => arr != null && arr.is_array() ? arr.get_len() : 0;

// Value of `Key:` in a `.meta` file ("" when missing). Temp.
fn String meta_value(String meta_path, String key)
{
	String? data = sys::read_temp(meta_path);
	if (catch data) return "";
	foreach (line : data.tsplit("\n"))
	{
		String l = line.trim();
		if (l.len > key.len && l.starts_with(key) && l[key.len] == ':') return l[key.len + 1..].trim();
	}
	return "";
}

fn long file_guid(String file)
{
	String b = txt::basename(file);
	sz i = 0;
	while (i < b.len && b[i] >= '0' && b[i] <= '9') i++;
	return b[:i].to_long() ?? 0;
}

fn bool has_walls(String path)
{
	String? data = sys::read_temp(path);
	if (catch data) return false;
	return data.contains("\"Walls\":[{");
}

fn Lot* add_lot(String path, String name, long guid, int street, bool premade)
{
	if (lot_count >= MAX_LOTS) return null;
	for (int i = 0; i < lot_count; i++) if (txt::view(&lots[i].path) == path) return null;
	if (!has_walls(path)) return null;
	Lot* l = &lots[lot_count++];
	*l = {};
	txt::set(&l.path, path);
	txt::set(&l.name, name);
	l.guid = guid;
	l.street = street;
	l.premade = premade;
	return l;
}

// Open a `.saved` folder, a folder of `.lot` files, or one `.lot` file. Lists the lots with buildings (no geometry yet).
fn bool open(String path) => @pool()
{
	lot_count = 0;
	cur_lot = -1;
	clear_lot();
	load_error[0] = 0;
	char[1024] real;
	sys::realpath(&real, path);
	path = txt::view(&real);
	txt::set(&save_path, path);
	String base = txt::basename(path);
	txt::set(&save_name, txt::iends_with(base, ".saved") ? base[:base.len - 6] : txt::strip_ext(base));
	if (sys::is_file(path))
	{
		if (!txt::iends_with(path, ".lot")) { txt::set(&load_error, "Not a Paralives .lot file"); return false; }
		String name = meta_value(string::tformat("%s.meta", path), "PremadeLotName");
		if (!add_lot(path, name.len ? name : txt::strip_ext(base), file_guid(path), 0, false)) txt::set(&load_error, "No walls in this lot");
		return lot_count > 0;
	}
	if (!sys::is_dir(path)) { txt::set(&load_error, "Not found"); return false; }

	sys::Entry[] ents = mem::talloc_array(sys::Entry, 4096);
	int n = sys::list_dir(path, ents, false);
	String town;
	for (int i = 0; i < n; i++)
	{
		if (ents[i].dir && txt::iends_with(txt::view(&ents[i].name), ".town")) town = txt::join(path, txt::view(&ents[i].name));
	}
	if (town.len)
	{
		open_town(path, town, ents[:n]);
	}
	else
	{
		for (int i = 0; i < n; i++)
		{
			String f = txt::view(&ents[i].name);
			if (ents[i].dir || !txt::iends_with(f, ".lot")) continue;
			String p = txt::join(path, f);
			String name = meta_value(string::tformat("%s.meta", p), "PremadeLotName");
			add_lot(p, name.len ? name : txt::strip_ext(f), file_guid(f), 0, false);
		}
	}
	if (!lot_count) txt::set(&load_error, "No buildings found in this save");
	// Same name twice (several "Your household" lots): add the street number, else a counter.
	int[MAX_LOTS] dup;     // 0 unique, else 1-based number among equal names
	for (int i = 0; i < lot_count; i++)
	{
		int same = 0;
		bool twin = false;
		for (int j = 0; j < lot_count; j++)
		{
			if (j == i || txt::view(&lots[j].name) != txt::view(&lots[i].name)) continue;
			twin = true;
			if (j < i) same++;
		}
		dup[i] = twin ? same + 1 : 0;
	}
	for (int i = 0; i < lot_count; i++)
	{
		if (!dup[i]) continue;
		String nm = lots[i].street ? string::tformat("%s (No. %d)", txt::view(&lots[i].name), lots[i].street) : string::tformat("%s (%d)", txt::view(&lots[i].name), dup[i]);
		txt::set(&lots[i].name, nm);
	}
	return lot_count > 0;
}

fn void open_town(String save, String town, sys::Entry[] save_ents)
{
	// Household names by owned lot.
	HashMap{long, String} owner;
	owner.tinit();
	long current = 0;     // the household being played
	String? simp = sys::read_temp(string::tformat("%s/%s.import", save, txt::basename(save)));
	if (try simp)
	{
		if (try Object* si = json::tparse(simp)) current = lng(si, "CurrentHouseholdGUID");
	}
	foreach (&e : save_ents)
	{
		String d = txt::view(&e.name);
		if (!e.dir || !txt::iends_with(d, ".household")) continue;
		String imp = string::tformat("%s/%s/%s.import", save, d, d);
		String? data = sys::read_temp(imp);
		if (catch data) continue;
		Object*? h = json::tparse(data);
		if (catch h) continue;
		String hn = str(h, "HouseholdName");
		Object* owned = sub(h, "OwnedLots");
		for (sz k = 0; k < count(owned); k++)
		{
			long g = owned.get_long_at(k) ?? 0;
			if (!g) continue;
			if (hn.len) { owner.set(g, string::tformat("%s Household", hn)); }
			else if (file_guid(d) == current) { owner.set(g, "Your home"); }
		}
	}

	sys::Entry[] ents = mem::talloc_array(sys::Entry, 4096);
	int n = sys::list_dir(town, ents, false);
	String premade_dir = txt::empty(&game_dir) ? "" : txt::join(txt::view(&game_dir), "Main.mod/PremadeLots");
	for (int i = 0; i < n; i++)
	{
		String f = txt::view(&ents[i].name);
		if (ents[i].dir || !txt::iends_with(f, ".lotperimeters")) continue;
		String? data = sys::read_temp(txt::join(town, f));
		if (catch data) continue;
		Object*? root = json::tparse(data);
		if (catch root) continue;
		Object* zones = sub(root, "Zones");
		for (sz z = 0; z < count(zones); z++)
		{
			Object* ld = sub(zones.get_at(z), "LotData");
			long g = lng(ld, "LotGUID");
			if (!g) continue;
			int street = (int)lng(ld, "StreetNumber");
			String own = txt::join(town, string::tformat("%d.lot", g));
			bool premade = !sys::is_file(own) || (sys::read_temp(own) ?? "").len == 0;
			String path = own;
			if (premade)
			{
				long p = lng(ld, "ProxyPremadeLotGUID");
				if (!p || !premade_dir.len) continue;
				path = txt::join(premade_dir, string::tformat("%d.lot", p));
				if (!sys::is_file(path)) continue;
			}
			String name = str(ld, "DisplayName");
			if (!name.len) name = owner.get(g) ?? "";
			if (!name.len && premade) name = meta_value(string::tformat("%s.meta", path), "PremadeLotName");
			if (!name.len) name = street ? string::tformat("No. %d", street) : string::tformat("Lot %d", g);
			add_lot(path, name, g, street, premade);
		}
	}
	// Lots on disk that no perimeter names (TownLot.lot is the empty town ground).
	for (int i = 0; i < n; i++)
	{
		String f = txt::view(&ents[i].name);
		if (ents[i].dir || !txt::iends_with(f, ".lot")) continue;
		long g = file_guid(f);
		String name = owner.get(g) ?? "";
		add_lot(txt::join(town, f), name.len ? name : txt::strip_ext(f), g, 0, false);
	}
}

// Catalogue names, once, from the game install found by discover() (or next to an opened premade lot).
fn void load_catalogue() => @pool()
{
	if (cat_tried) return;
	cat_tried = true;
	if (txt::empty(&game_dir)) return;
	String? data = sys::read_temp(txt::join(txt::view(&game_dir), "Main.mod/Settings/Items.setting"));
	if (catch data) return;
	catalogue = mem::new_array(CatName, MAX_CATALOGUE);
	long guid = 0;
	foreach (line : data.tsplit("\n"))
	{
		// Top-level item fields are indented by three spaces: "   =GUID:..." then "   =DisplayName:...".
		if (line.len < 5 || line[:4] != "   =" || line[4] == ' ') continue;
		String l = line[4..].trim();
		if (l.starts_with("GUID:")) { guid = l[5..].to_long() ?? 0; continue; }
		if (l.starts_with("DisplayName:") && guid && cat_count < MAX_CATALOGUE)
		{
			catalogue[cat_count].guid = guid;
			txt::set(&catalogue[cat_count].name, l[12..]);
			cat_count++;
			guid = 0;
		}
	}
}

fn String cat_name(long guid)
{
	for (int i = 0; i < cat_count; i++) if (catalogue[i].guid == guid) return txt::view(&catalogue[i].name);
	return "";
}

fn Kind classify(String name, Item* it)
{
	if (!name.len)
	{
		// No game install: guess from shape. Wall items that reach the floor and are door-high are doors.
		if (it.on != 1) return it.on == 2 ? FURNITURE : OTHER;
		if (it.dz > 0.5f || it.dx < 0.4f) return OTHER;
		return it.y - it.dy * 0.5f < 0.15f && it.dy > 1.7f ? DOOR : WINDOW;
	}
	if (name.starts_with("Door")) return DOOR;
	if (name.starts_with("Window") || name.starts_with("ArchitectureWindow")) return WINDOW;
	if (name.starts_with("Arch") && !name.starts_with("Architecture")) return ARCH;
	if (name.starts_with("Stairs")) return STAIRS;
	if (name.starts_with("Roof") || name.starts_with("Chimney")) return ROOF;
	if (it.on == 1) return OTHER;   // shutters, shelves, pictures on walls
	return FURNITURE;
}

fn void clear_lot()
{
	nodes.clear();
	walls.clear();
	rooms.clear();
	room_pts.clear();
	items.clear();
	level_count = 0;
}

fn int node_index(HashMap{long, int}* ids, long id) => ids.get(id) ?? -1;

fn void add_level(int l)
{
	for (int i = 0; i < level_count; i++) if (levels[i] == l) return;
	if (level_count >= MAX_LEVELS) return;
	int i = level_count++;
	while (i > 0 && levels[i - 1] > l) { levels[i] = levels[i - 1]; i--; }
	levels[i] = l;
}

// Quadratic Bezier point.
fn float[<2>] bez(float[<2>] a, float[<2>] c, float[<2>] b, float t)
{
	float u = 1 - t;
	return a * (u * u) + c * (2 * u * t) + b * (t * t);
}
const CURVE_STEPS = 16;

fn float[<2>] node_pos(int i) => { nodes[i].x, nodes[i].z };

// Parse one lot's geometry (on selection; ~1 MB JSON at most).
fn bool load_lot(int index) => @pool()
{
	clear_lot();
	cur_lot = index;
	load_catalogue();
	String? data = sys::read_temp(txt::view(&lots[index].path));
	if (catch data) { txt::set(&load_error, "Cannot read the lot file"); return false; }
	Object*? root = json::tparse(data);
	if (catch root) { txt::set(&load_error, "The lot file is not valid JSON"); return false; }

	HashMap{long, int} ids;
	ids.tinit();
	Object* arr = sub(root, "Nodes");
	for (sz i = 0; i < count(arr); i++)
	{
		Object* o = arr.get_at(i);
		Object* p = sub(o, "Position");
		ids.set(lng(o, "InstanceID"), (int)nodes.len());
		nodes.push({ lng(o, "InstanceID"), num(p, "x"), num(p, "z") });
	}
	HashMap{long, int} wall_ids;
	wall_ids.tinit();
	arr = sub(root, "Walls");
	for (sz i = 0; i < count(arr); i++)
	{
		Object* o = arr.get_at(i);
		Wall w = { .id = lng(o, "InstanceID"), .layer = (int)lng(o, "Layer"), .thick = num(o, "Thickness") * 0.1f, .placed_at = (int)lng(o, "PlacedAtHeight") };
		w.a = node_index(&ids, lng(o, "NodeAInstanceID"));
		w.b = node_index(&ids, lng(o, "NodeBInstanceID"));
		if (w.a < 0 || w.b < 0) continue;
		Object* q = sub(o, "QuadraticBezierPosition");
		float qx = num(q, "x");
		float qz = num(q, "z");
		w.curved = math::abs(qx) > 1e-4f || math::abs(qz) > 1e-4f;
		// The control point is stored relative to node A.
		w.cx = nodes[w.a].x + qx;
		w.cz = nodes[w.a].z + qz;
		Object* secs = sub(o, "WallSections");
		sz ns = count(secs);
		bool fence = ns > 0;
		bool all_off = ns > 0;
		for (sz s = 0; s < ns; s++)
		{
			if (!flag(secs.get_at(s), "IsFence")) fence = false;
			if (!flag(secs.get_at(s), "IsDisabled")) all_off = false;
		}
		if (all_off) continue;
		w.fence = fence;
		if (w.thick <= 0) w.thick = 0.2f;
		wall_ids.set(w.id, (int)walls.len());
		walls.push(w);
		add_level(w.layer);
	}
	arr = sub(root, "Zones");
	for (sz i = 0; i < count(arr); i++)
	{
		Object* o = arr.get_at(i);
		Object* segs = sub(o, "SegmentInstanceIDs");
		sz ns = count(segs);
		if (ns < 3) continue;
		Room r = { .id = lng(o, "InstanceID"), .layer = (int)lng(o, "Layer"), .area = num(o, "SurfaceArea") };
		Object* ap = sub(o, "AveragePosition");
		r.ax = num(ap, "x");
		r.az = num(ap, "z");
		r.p0 = (int)room_pts.len();
		for (sz s = 0; s < ns; s++)
		{
			Object* so = segs.get_at(s);
			int first = node_index(&ids, lng(so, "FirstNodeEntityInstanceID"));
			if (first < 0) continue;
			room_pts.push(node_pos(first));
			int wi = wall_ids.get(lng(so, "SegmentEntityInstanceID")) ?? -1;
			if (wi < 0 || !walls[wi].curved) continue;
			Wall* w = walls.get_ref(wi);
			float[<2>] a = node_pos(w.a);
			float[<2>] b = node_pos(w.b);
			float[<2>] c = { w.cx, w.cz };
			bool fwd = first == w.a;
			for (int k = 1; k < CURVE_STEPS; k++)
			{
				float t = (float)k / CURVE_STEPS;
				room_pts.push(bez(a, c, b, fwd ? t : 1 - t));
			}
		}
		r.pn = (int)room_pts.len() - r.p0;
		if (r.pn < 3) { while (room_pts.len() > r.p0) room_pts.pop()!!; continue; }
		rooms.push(r);
		add_level(r.layer);
	}
	arr = sub(root, "Items");
	for (sz i = 0; i < count(arr); i++)
	{
		Object* o = arr.get_at(i);
		Object* p = sub(o, "Position");
		Object* q = sub(o, "Rotation");
		Object* s = sub(o, "Size");
		Item it = {
			.cat = lng(o, "CatalogueGUID"),
			.x = num(p, "x"), .y = num(p, "y"), .z = num(p, "z"),
			.ang = 2 * math::atan2(num(q, "y"), num(q, "w")),
			.dx = num(s, "x"), .dy = num(s, "y"), .dz = num(s, "z"),
			.layer = (int)lng(o, "Layer"),
			.on = (int)lng(sub(o, "PlacedOn"), "Type"),
			.flipped = flag(o, "Flipped"),
		};
		String name = cat_name(it.cat);
		txt::set(&it.name, name);
		it.kind = classify(name, &it);
		if (it.kind == OTHER || it.kind == ROOF) continue;
		items.push(it);
	}
	foreach (&r : rooms) guess_room_name(r);
	// Ground floor: the lowest level whose walls mostly stand at or above the ground.
	ground = 0;
	for (int i = 0; i < level_count; i++)
	{
		int up, down;
		foreach (&w : walls) if (w.layer == levels[i]) { if (w.placed_at < 0) { down++; } else { up++; } }
		if (up >= down) { ground = i; break; }
	}
	return true;
}

fn bool inside(float[<2>][] poly, float[<2>] p)
{
	bool in = false;
	sz n = poly.len;
	sz j = n - 1;
	for (sz i = 0; i < n; j = i++)
	{
		float[<2>] a = poly[i];
		float[<2>] b = poly[j];
		if ((a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) in = !in;
	}
	return in;
}

fn float[<2>][] room_poly(Room* r) => room_pts.array_view()[r.p0:r.pn];

// Room type from the furniture standing in it. Highest rank wins.
fn void guess_room_name(Room* r)
{
	String best = "Room";
	int rank = 0;
	foreach (&it : items)
	{
		if (it.layer != r.layer || it.kind != FURNITURE) continue;
		if (!inside(room_poly(r), { it.x, it.z })) continue;
		String n = txt::view(&it.name);
		String guess;
		int k;
		switch
		{
			case n.starts_with("PlumbingToilet") || n.starts_with("PlumbingShower") || n.starts_with("PlumbingTub") || n.starts_with("PlumbingBathtub"): guess = "Bathroom"; k = 6;
			case n.starts_with("BeddingCrib"): guess = "Nursery"; k = 5;
			case n.starts_with("Bedding") || n.starts_with("Bed"): guess = "Bedroom"; k = 5;
			case n.starts_with("ApplianceFridge") || n.starts_with("ApplianceOven") || n.starts_with("SurfaceCounter"): guess = "Kitchen"; k = 4;
			case n.starts_with("ApplianceWasher") || n.starts_with("ApplianceDryer"): guess = "Laundry"; k = 3;
			case n.starts_with("SeatingCouch") || n.starts_with("SeatingArmchair") || n.starts_with("Fireplace"): guess = "Living room"; k = 2;
			case n.starts_with("SurfaceDesk") || n.starts_with("ElectronicComputer"): guess = "Study"; k = 1;
		}
		if (k > rank) { rank = k; best = guess; }
	}
	txt::set(&r.auto_name, best);
	txt::set(&r.name, best);
}

// "Ground floor", "First floor", "Basement"... Temp.
fn String level_name(int layer)
{
	int idx = 0;
	for (int i = 0; i < level_count; i++) if (levels[i] == layer) idx = i;
	int rel = idx - ground;
	switch (rel)
	{
		case 0: return "Ground floor";
		case 1: return "First floor";
		case 2: return "Second floor";
		case 3: return "Third floor";
		case -1: return "Basement";
		default: return rel < 0 ? string::tformat("Basement %d", -rel) : string::tformat("Floor %d", rel);
	}
}
