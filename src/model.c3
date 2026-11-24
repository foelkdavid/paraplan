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
const MAX_BUILDINGS = 64;

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
	int bld;              // building index, -1 = none (fences, stray bits)
	float len;            // centre-line length, metres
}

struct Room
{
	long id;
	int layer;
	float area;           // m², as the game reports it (wall centre lines)
	float perim;          // outline length on the wall centre lines, metres
	int node0;            // first outline node (finds the building)
	int nseg;             // walls around it
	int bld;
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
	int bld;              // building it stands in / on, -1 = outside every building
	char[48] name;
}

// A building: walls connected to each other on one level, stacked levels merged by their overlap.
struct Building
{
	float area;           // m², all levels
	float wall_len;       // metres of wall (centre lines), all levels
	float angle;          // dominant wall direction in sheet coords (x, -z), radians in (-pi/4, pi/4]
	int rooms;
	int levels;
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
Building[MAX_BUILDINGS] buildings;
int building_count;

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
	building_count = 0;
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
		Room r = { .id = lng(o, "InstanceID"), .layer = (int)lng(o, "Layer"), .area = num(o, "SurfaceArea"), .node0 = -1, .bld = -1 };
		Object* ap = sub(o, "AveragePosition");
		r.ax = num(ap, "x");
		r.az = num(ap, "z");
		r.p0 = (int)room_pts.len();
		for (sz s = 0; s < ns; s++)
		{
			Object* so = segs.get_at(s);
			int first = node_index(&ids, lng(so, "FirstNodeEntityInstanceID"));
			if (first < 0) continue;
			if (r.node0 < 0) r.node0 = first;
			r.nseg++;
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
	find_buildings();
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

fn float poly_len(float[<2>][] p)
{
	float l = 0;
	for (sz i = 0; i < p.len; i++) l += (p[(i + 1) % p.len] - p[i]).length();
	return l;
}

fn float wall_length(Wall* w)
{
	float[<2>] a = node_pos(w.a);
	float[<2>] b = node_pos(w.b);
	if (!w.curved) return (b - a).length();
	float l = 0;
	float[<2>] prev = a;
	for (int i = 1; i <= CURVE_STEPS; i++)
	{
		float[<2>] q = bez(a, { w.cx, w.cz }, b, (float)i / CURVE_STEPS);
		l += (q - prev).length();
		prev = q;
	}
	return l;
}

fn int uf_find(int[] p, int i)
{
	while (p[i] != i) { p[i] = p[p[i]]; i = p[i]; }
	return i;
}

fn void uf_join(int[] p, int a, int b)
{
	a = uf_find(p, a);
	b = uf_find(p, b);
	if (a != b) p[a] = b;
}

// Buildings: (1) walls joined at nodes form one piece per level; (2) pieces merge when one sits on top of the
// other (different levels, boxes overlap by 30 % of the smaller) or inside it (same level, 90 %: a free-standing
// wall in a room). Rooms follow their first node, items the room they stand in, else the nearest wall (< 1.5 m).
// Buildings are numbered by floor area, largest first.
fn void find_buildings() => @pool()
{
	building_count = 0;
	sz nn = nodes.len();
	foreach (&r : rooms) { r.bld = -1; r.perim = poly_len(room_poly(r)); }
	foreach (&w : walls) { w.bld = -1; w.len = wall_length(w); }
	foreach (&it : items) it.bld = -1;
	if (!nn) return;
	int[] parent = mem::talloc_array(int, nn);
	for (sz i = 0; i < nn; i++) parent[i] = (int)i;
	foreach (&w : walls) if (!w.fence) uf_join(parent, w.a, w.b);
	// piece boxes, keyed by root node
	float[<4>][] box = mem::talloc_array(float[<4>], nn);   // x0 z0 x1 z1
	int[] layer = mem::talloc_array(int, nn);
	bool[] used = mem::talloc_array(bool, nn);
	for (sz i = 0; i < nn; i++) { box[i] = { 1e9, 1e9, -1e9, -1e9 }; used[i] = false; }
	foreach (&w : walls)
	{
		if (w.fence) continue;
		int r = uf_find(parent, w.a);
		used[r] = true;
		layer[r] = w.layer;
		foreach (n : (int[2]){ w.a, w.b })
		{
			box[r].x = math::min(box[r].x, nodes[n].x);
			box[r].y = math::min(box[r].y, nodes[n].z);
			box[r].z = math::max(box[r].z, nodes[n].x);
			box[r].w = math::max(box[r].w, nodes[n].z);
		}
	}
	// merge pieces (repeat until stable: merged boxes grow)
	int[] group = mem::talloc_array(int, nn);
	for (sz i = 0; i < nn; i++) group[i] = (int)i;
	bool changed = true;
	while (changed)
	{
		changed = false;
		for (sz i = 0; i < nn; i++)
		{
			if (!used[i]) continue;
			for (sz j = i + 1; j < nn; j++)
			{
				if (!used[j] || uf_find(group, (int)i) == uf_find(group, (int)j)) continue;
				float[<4>] a = box[i];
				float[<4>] b = box[j];
				float ox = math::min(a.z, b.z) - math::max(a.x, b.x);
				float oz = math::min(a.w, b.w) - math::max(a.y, b.y);
				if (ox <= 0 || oz <= 0) continue;
				float sa = math::max((a.z - a.x) * (a.w - a.y), 1e-4f);
				float sb = math::max((b.z - b.x) * (b.w - b.y), 1e-4f);
				float frac = ox * oz / math::min(sa, sb);
				if (frac >= (layer[i] == layer[j] ? 0.9f : 0.3f)) { uf_join(group, (int)i, (int)j); changed = true; }
			}
		}
	}
	// group root -> provisional building number
	int[] num_of = mem::talloc_array(int, nn);
	for (sz i = 0; i < nn; i++) num_of[i] = -1;
	int count = 0;
	for (sz i = 0; i < nn; i++)
	{
		if (!used[i]) continue;
		int g = uf_find(group, (int)i);
		if (num_of[g] < 0 && count < MAX_BUILDINGS) num_of[g] = count++;
	}
	Building[MAX_BUILDINGS] b;
	uint[MAX_BUILDINGS] lv;            // level bits
	foreach (&w : walls)
	{
		if (w.fence) continue;
		w.bld = num_of[uf_find(group, uf_find(parent, w.a))];
		if (w.bld < 0) continue;
		b[w.bld].wall_len += w.len;
	}
	foreach (&r : rooms)
	{
		if (r.node0 < 0) continue;
		int ni = r.node0;
		int g = used[uf_find(parent, ni)] ? num_of[uf_find(group, uf_find(parent, ni))] : -1;
		r.bld = g;
		if (g < 0) continue;
		b[g].area += r.area;
		b[g].rooms++;
	}
	foreach (&w : walls) if (w.bld >= 0) lv[w.bld] |= 1u << (uint)math::clamp(level_slot(w.layer), 0, 31);
	foreach (&it : items)
	{
		float[<2>] p = { it.x, it.z };
		foreach (&r : rooms) if (r.bld >= 0 && r.layer == it.layer && inside(room_poly(r), p)) { it.bld = r.bld; break; }
		if (it.bld >= 0) continue;
		float best = 1.5f;
		foreach (&w : walls)
		{
			if (w.bld < 0 || w.layer != it.layer) continue;
			float[<2>] a = node_pos(w.a);
			float[<2>] d = node_pos(w.b) - a;
			float l2 = d.dot(d);
			float u = l2 > 0 ? math::clamp((p - a).dot(d) / l2, 0.0f, 1.0f) : 0;
			float dist = (a + d * u - p).length();
			if (dist < best) { best = dist; it.bld = w.bld; }
		}
	}
	for (int i = 0; i < count; i++)
	{
		b[i].angle = main_angle(i);
		for (uint k = lv[i]; k; k &= k - 1) b[i].levels++;
	}
	// largest first
	int[MAX_BUILDINGS] order;
	for (int i = 0; i < count; i++) order[i] = i;
	for (int i = 1; i < count; i++)
	{
		int v = order[i];
		int j = i;
		while (j > 0 && key(&b[order[j - 1]]) < key(&b[v])) { order[j] = order[j - 1]; j--; }
		order[j] = v;
	}
	int[MAX_BUILDINGS] rank;
	for (int i = 0; i < count; i++) { rank[order[i]] = i; buildings[i] = b[order[i]]; }
	foreach (&w : walls) if (w.bld >= 0) w.bld = rank[w.bld];
	foreach (&r : rooms) if (r.bld >= 0) r.bld = rank[r.bld];
	foreach (&it : items) if (it.bld >= 0) it.bld = rank[it.bld];
	building_count = count;
}

// Wall direction (modulo 90°, sheet coords) carried by the most wall length (straight walls within ±2°), refined
// to the length-weighted mean of those walls. Odd shapes follow their longest run, not an average of every wall.
fn float main_angle(int bld)
{
	float best = 0;
	float[<2>] best_dir = { 1, 0 };
	foreach (&w : walls)
	{
		if (w.bld != bld || w.curved || w.len < 0.05f) continue;
		float a = dir4(w);
		float support = 0;
		float[<2>] sum = {};
		foreach (&v : walls)
		{
			if (v.bld != bld || v.curved || v.len < 0.05f) continue;
			float c = dir4(v);
			float diff = math::abs(math::atan2(math::sin(c - a), math::cos(c - a)));   // in 4x angle space
			if (diff > 4 * 2 * (float)math::PI / 180) continue;
			support += v.len;
			sum += { math::cos(c) * v.len, math::sin(c) * v.len };
		}
		if (support > best + 1e-4f) { best = support; best_dir = sum; }
	}
	float ang = math::atan2(best_dir.y, best_dir.x) / 4;
	return math::abs(ang) < 0.002f ? 0 : ang;
}

// 4 × the wall's direction on the sheet (x, -z): walls at 90° to each other agree.
fn float dir4(Wall* w)
{
	float[<2>] d = node_pos(w.b) - node_pos(w.a);
	return math::atan2(-d.y, d.x) * 4;
}

fn float key(Building* b) => b.area * 1000 + b.wall_len;

fn int level_slot(int layer)
{
	for (int i = 0; i < level_count; i++) if (levels[i] == layer) return i;
	return 0;
}
