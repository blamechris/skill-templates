// LookApproveCapture.cs — the Unity capture adapter for /look-approve.
//
// Drives a scene through a scripted tour in play mode and writes one PNG per
// capture frame, plus the manifests the approval card is built from. Assembling
// the GIF and the stills happens OUTSIDE Unity (ffmpeg), so this file's only job
// is deterministic frames and an honest record of what was staged to get them.
//
// INSTALL: drop into any folder named `Editor/` in the target project (Unity
// generates the .meta itself). It references no project types — everything
// project-specific arrives as JSON in LOOKAPPROVE_TOUR. Delete it when the
// approval pass is done; /look-approve is capture-only and commits nothing.
//
// RUN (headed editor — `-batchmode -nographics` cannot render a frame):
//   LOOKAPPROVE_OUT=<frames-dir> \
//   LOOKAPPROVE_TOUR=<tour.json> \
//   LOOKAPPROVE_SAVES=backed-up \
//   "<UnityEditorPath>/Unity" -projectPath <worktree> \
//        -executeMethod LookApprove.EditorTools.LookApproveCapture.Run \
//        -logFile <log>
//
// ENVIRONMENT
//   LOOKAPPROVE_OUT    frames + manifests output dir (default /tmp/lookapprove)
//   LOOKAPPROVE_TOUR   path to the tour spec JSON (schema: TourSpec below)
//   LOOKAPPROVE_SAVES  interlock, REQUIRED. `backed-up` = the caller has copied
//                      the user's real save/profile data somewhere safe and will
//                      restore it; `none` = this project writes no such state.
//                      Any other value aborts before play mode. Play mode runs
//                      the real game against the real save location: the
//                      prototype that this adapter came from overwrote a live
//                      save exactly once, and this interlock is why it cannot
//                      happen again.
//
// COMPLETION is signalled by `_DONE.txt` in LOOKAPPROVE_OUT — ALWAYS, including
// on abort. Wait on that file, never on CPU or log activity: a cold Library
// compiles shaders for ~90s at the first frame and looks indistinguishable from
// a hang.
//
// OUTPUT in LOOKAPPROVE_OUT
//   frame_NNNN.png   capture frames, in order, at the spec's fps
//   _STILLS.json     {label -> frame index} for every beat carrying a `still`
//   _STAGED.txt      one line per cue actually fired — the honesty record that
//                    the approval card's callout is built from
//   _RUN.json        editor version, scene, resolution, fps, frame count
//   _DONE.txt        sentinel: reason + frame count (written on success AND abort)

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

namespace LookApprove.EditorTools
{
    // ---------------------------------------------------------------- spec

    /// <summary>
    /// The tour, as JSON. Parsed with JsonUtility, so: public fields, arrays
    /// (no dictionaries), no properties.
    /// </summary>
    [Serializable]
    public class TourSpec
    {
        public string scene;                 // e.g. "Assets/Scenes/Game.unity"
        public int width = 720;              // Game View pixels — portrait by default
        public int height = 1280;
        public int fps = 15;                 // capture framerate (Time.captureFramerate)
        public int settleFrames = 12;        // discarded before the first capture
        public int flushFrames = 25;         // idle tail so async PNG writes land
        public string[] hideBehaviours;      // Behaviour type names to disable (debug overlays)
        public string[] dismissModals;       // component type names with a public Dismiss()
        public string playerType = "CharacterController"; // component driven by `walk` beats
        public Beat[] beats;
    }

    [Serializable]
    public class Beat
    {
        public string kind;        // "hold" | "walk" | "cue"
        public int frames;         // duration in capture frames ("cue" ignores it)
        public string label;       // free-text, for the log

        // walk
        public string target;      // GameObject name to approach
        public float standoff = 2f;// stop this far short, in world units

        // hold / walk
        public string still;       // emit a still here, labelled with this string.
                                   // ONE still per feature/PR under review — the
                                   // label is what the card maps to that PR.

        // cue
        public string invoke;      // "TypeName.MethodName" — a MonoBehaviour in the
                                   // scene, else a static method on a loaded type
        public string[] args;      // parsed to the method's parameter types
        public string declare;     // MANDATORY for a cue. Plain-English statement of
                                   // what this cue staged, e.g. "customer arrivals
                                   // were forced — the spawner's own interval is 15s
                                   // and the tour is 14s". Lands verbatim in
                                   // _STAGED.txt and MUST reach the approval card.
    }

    // ---------------------------------------------------------------- driver

    public static class LookApproveCapture
    {
        private const string KeyActive = "LookApprove.Active";
        private const string KeyOut = "LookApprove.Out";
        private const string KeyTour = "LookApprove.Tour";
        private const string KeyStep = "LookApprove.Step";
        private const string KeyEntered = "LookApprove.Entered";

        private static string _outDir;
        private static TourSpec _spec;
        private static bool _hooked;

        // Rebuilt lazily after every domain reload.
        private static Transform _player;
        private static Component _mover;
        private static MethodInfo _moveMethod;
        private static Vector3 _legTarget;
        private static bool _legTargetSet;
        private static bool _sceneReady;
        private static int _activeBeat = -1;
        private static int _lastGameFrame = -1;
        private static int _capturedCount;
        private static readonly List<string> Stills = new List<string>();

        // ------------------------------------------------------------ entry

        public static void Run()
        {
            _outDir = Env("LOOKAPPROVE_OUT", "/tmp/lookapprove");
            Directory.CreateDirectory(_outDir);

            // Save-data interlock. Checked FIRST, before anything opens a scene:
            // play mode writes to the real save location, and a run that has not
            // declared its intent about that must not start.
            var saves = Env("LOOKAPPROVE_SAVES", "");
            if (saves != "backed-up" && saves != "none")
            {
                Abort("LOOKAPPROVE_SAVES must be 'backed-up' (caller saved and will restore " +
                      "the real save/profile data) or 'none' (this project writes none). " +
                      "Refusing to enter play mode against unprotected save data.");
                return;
            }

            var tourPath = Env("LOOKAPPROVE_TOUR", "");
            if (string.IsNullOrEmpty(tourPath) || !File.Exists(tourPath))
            {
                Abort($"tour spec not found (LOOKAPPROVE_TOUR='{tourPath}')");
                return;
            }

            try { _spec = JsonUtility.FromJson<TourSpec>(File.ReadAllText(tourPath)); }
            catch (Exception e) { Abort($"tour spec unreadable: {e.Message}"); return; }

            if (_spec == null || _spec.beats == null || _spec.beats.Length == 0)
            {
                Abort("tour spec has no beats");
                return;
            }
            if (string.IsNullOrEmpty(_spec.scene) || !File.Exists(_spec.scene))
            {
                Abort($"scene not found: '{_spec.scene}'");
                return;
            }

            // Every cue must declare itself, and that is checked BEFORE the run
            // rather than at fire time — an undeclared cue is a spec bug, and the
            // honest failure is to refuse the whole capture, not to produce a
            // card that quietly omits it.
            for (var i = 0; i < _spec.beats.Length; i++)
            {
                var b = _spec.beats[i];
                if (b.kind == "cue" && string.IsNullOrEmpty(b.declare))
                {
                    Abort($"beat {i} is a cue with no `declare` — every staged action must be " +
                          "declared on the approval card. Add `declare` and re-run.");
                    return;
                }
            }

            SessionState.SetString(KeyOut, _outDir);
            SessionState.SetString(KeyTour, tourPath);
            SessionState.SetBool(KeyActive, true);
            SessionState.SetInt(KeyStep, 0);
            SessionState.SetBool(KeyEntered, false);

            Debug.Log($"[LookApprove] starting, out={_outDir}, scene={_spec.scene}, saves={saves}");

            ConfigureGameView(_spec.width, _spec.height);
            EditorSceneManager.OpenScene(_spec.scene, OpenSceneMode.Single);
            Hook();
        }

        /// <summary>
        /// Entering play mode reloads the domain and wipes every static above, so
        /// the run re-attaches here and reads its position back out of
        /// SessionState (which survives the reload; static fields do not).
        /// </summary>
        [InitializeOnLoadMethod]
        private static void OnDomainLoad()
        {
            if (!SessionState.GetBool(KeyActive, false)) return;
            _outDir = SessionState.GetString(KeyOut, "/tmp/lookapprove");
            var tourPath = SessionState.GetString(KeyTour, "");
            try { _spec = JsonUtility.FromJson<TourSpec>(File.ReadAllText(tourPath)); }
            catch (Exception e) { Abort($"tour spec unreadable after domain reload: {e.Message}"); return; }
            Hook();
        }

        private static void Hook()
        {
            if (_hooked) return;
            _hooked = true;
            EditorApplication.update += Tick;
        }

        // ------------------------------------------------------------ tick

        private static void Tick()
        {
            if (!SessionState.GetBool(KeyActive, false)) return;

            // 1. Get into play mode once the editor is idle. Entering while it is
            //    compiling or importing drops the request on the floor.
            if (!EditorApplication.isPlayingOrWillChangePlaymode)
            {
                if (SessionState.GetBool(KeyEntered, false))
                {
                    Finish("play mode exited before the tour finished");  // bail out honestly
                    return;
                }
                if (EditorApplication.isCompiling || EditorApplication.isUpdating) return;
                SessionState.SetBool(KeyEntered, true);
                Debug.Log("[LookApprove] entering play mode");
                EditorApplication.EnterPlaymode();
                return;
            }

            if (!EditorApplication.isPlaying) return;       // still transitioning
            if (Time.frameCount == _lastGameFrame) return;  // exactly one step per GAME frame:
            _lastGameFrame = Time.frameCount;               // editor ticks are not frames

            if (!EnsureScene()) return;                     // scene not booted yet

            var step = SessionState.GetInt(KeyStep, 0);
            Advance(step);
            SessionState.SetInt(KeyStep, step + 1);
        }

        private static bool EnsureScene()
        {
            if (_sceneReady) return true;

            // The player is optional: a tour of pure `hold` beats is legitimate.
            //
            // The Find*ByType overloads used here span 2022.2 → 6000.x. Unity
            // 6000.4 deprecates them (CS0618, warning only). If the project builds
            // with warnings-as-errors, swap to FindAnyObjectByType(Type) and the
            // FindObjectsByType overload without FindObjectsSortMode — but note
            // those do not exist on older editors, so the swap costs portability.
            var moverType = ResolveType(_spec.playerType);
            if (moverType != null)
            {
                var found = UnityEngine.Object.FindFirstObjectByType(moverType) as Component;
                if (found != null)
                {
                    _mover = found;
                    _player = found.transform;
                    _moveMethod = moverType.GetMethod("Move", new[] { typeof(Vector3) });
                }
            }

            // Deterministic, drop-free capture cadence: the engine advances time
            // by exactly 1/fps per frame regardless of how slowly it renders.
            Time.captureFramerate = Mathf.Max(1, _spec.fps);

            // Editor-only debug overlays draw through OnGUI and would sit in every
            // frame of the tour. They are not part of what is being approved.
            foreach (var name in _spec.hideBehaviours ?? new string[0])
            {
                var t = ResolveType(name);
                if (t == null) { Debug.LogWarning($"[LookApprove] hideBehaviours: no type '{name}'"); continue; }
                foreach (var b in UnityEngine.Object.FindObjectsByType(t, FindObjectsSortMode.None))
                    if (b is Behaviour beh) beh.enabled = false;
            }

            // Boot-time modals (offline-progress screens, tutorials, consent
            // dialogs) pop over the establishing shot and hide the thing under
            // review. Dismiss them here; script the modal deliberately as a beat
            // if it is itself part of the review set.
            foreach (var name in _spec.dismissModals ?? new string[0])
            {
                var t = ResolveType(name);
                if (t == null) { Debug.LogWarning($"[LookApprove] dismissModals: no type '{name}'"); continue; }
                foreach (var m in UnityEngine.Object.FindObjectsByType(t, FindObjectsSortMode.None))
                    t.GetMethod("Dismiss", Type.EmptyTypes)?.Invoke(m, null);
            }

            _sceneReady = true;
            Debug.Log($"[LookApprove] scene ready (player={( _player == null ? "none" : _player.name)})");
            return true;
        }

        // ------------------------------------------------------------ scenario

        private static void Advance(int step)
        {
            var t = step;
            if (t < _spec.settleFrames) return;   // let the first frames settle
            t -= _spec.settleFrames;

            for (var i = 0; i < _spec.beats.Length; i++)
            {
                var beat = _spec.beats[i];

                if (beat.kind == "cue")
                {
                    // Cues are instantaneous. The loop re-enters from beat 0 every
                    // frame, so a cue is REACHED on every later frame too; it fires
                    // only on the one frame where the beats before it have just been
                    // exhausted (t == 0). That test is stateless, so it survives a
                    // domain reload — a fired-set of static ints would not.
                    if (t == 0) FireCue(beat);
                    continue;
                }

                if (t >= beat.frames) { t -= beat.frames; continue; }

                // Reset the leg target only on entering a new beat, not on every
                // frame: recomputing the approach point each frame lets it drift
                // as the player moves.
                if (i != _activeBeat) { _activeBeat = i; _legTargetSet = false; }

                if (beat.kind == "walk") StepTowardTarget(beat);
                if (!string.IsNullOrEmpty(beat.still) && t == beat.frames / 2)
                    Stills.Add($"\"{Escape(beat.still)}\": {_capturedCount}");
                Capture();
                return;
            }

            if (t < _spec.flushFrames) return;    // async PNG writes drain
            Finish("scenario complete");
        }

        private static void StepTowardTarget(Beat beat)
        {
            if (_player == null || _moveMethod == null || string.IsNullOrEmpty(beat.target)) return;

            if (!_legTargetSet)
            {
                var go = GameObject.Find(beat.target);
                if (go == null) { Debug.LogWarning($"[LookApprove] no GameObject '{beat.target}'"); return; }
                // Approach from wherever the player currently is, stopping short of
                // the target's own footprint but inside any interaction radius.
                var from = _player.position;
                var away = from - go.transform.position; away.y = 0f;
                if (away.sqrMagnitude < 0.01f) away = Vector3.back;
                _legTarget = go.transform.position + away.normalized * beat.standoff;
                _legTargetSet = true;
            }

            var dir = _legTarget - _player.position; dir.y = 0f;
            if (dir.magnitude < 0.12f) return;
            const float speed = 3.2f;                      // world units/second
            _moveMethod.Invoke(_mover, new object[] { dir.normalized * (speed / Mathf.Max(1, _spec.fps)) });
        }

        /// <summary>
        /// Fires one staged cue through the project's own public surface and
        /// records its declaration. A cue never fabricates state the game cannot
        /// produce — it makes something the game does anyway happen inside the
        /// 15 seconds the tour has. Whatever it stages is declared on the card.
        /// </summary>
        private static void FireCue(Beat beat)
        {
            var line = $"{beat.declare}   [cue: {beat.invoke}]";
            try
            {
                var dot = beat.invoke?.LastIndexOf('.') ?? -1;
                if (dot <= 0) throw new Exception($"malformed invoke '{beat.invoke}' (want Type.Method)");
                var typeName = beat.invoke.Substring(0, dot);
                var methodName = beat.invoke.Substring(dot + 1);

                var type = ResolveType(typeName) ?? throw new Exception($"no type '{typeName}'");
                var instance = UnityEngine.Object.FindFirstObjectByType(type) as Component;  // null ⇒ static
                var flags = BindingFlags.Public | (instance != null ? BindingFlags.Instance : BindingFlags.Static);
                var method = type.GetMethod(methodName, flags) ?? throw new Exception($"no method '{methodName}'");

                method.Invoke(instance, Coerce(method.GetParameters(), beat.args));
                RecordStaged(line);
                Debug.Log($"[LookApprove] cue fired: {beat.invoke}");
            }
            catch (Exception e)
            {
                // A failed cue is still recorded: the card must say the beat it was
                // meant to produce did NOT happen, rather than silently show
                // whatever the frame contained instead.
                RecordStaged($"{line}  — FAILED: {e.Message}");
                Debug.LogWarning($"[LookApprove] cue failed ({beat.invoke}): {e.Message}");
            }
        }

        /// <summary>
        /// Appends to _STAGED.txt the moment the cue fires, rather than holding the
        /// list until the sentinel. The honesty record is the one artifact that must
        /// not be lost to a crash, an early play-mode exit, or a domain reload.
        /// </summary>
        private static void RecordStaged(string line)
        {
            try { File.AppendAllText(Path.Combine(_outDir, "_STAGED.txt"), line + "\n"); }
            catch (Exception e) { Debug.LogWarning($"[LookApprove] could not append _STAGED.txt: {e.Message}"); }
        }

        private static object[] Coerce(ParameterInfo[] parameters, string[] args)
        {
            var n = parameters.Length;
            var values = new object[n];
            for (var i = 0; i < n; i++)
            {
                var raw = (args != null && i < args.Length) ? args[i] : null;
                var p = parameters[i].ParameterType;
                if (raw == null) { values[i] = p.IsValueType ? Activator.CreateInstance(p) : null; continue; }
                values[i] = p == typeof(string) ? raw
                    : p == typeof(int) ? (object)int.Parse(raw, CultureInfo.InvariantCulture)
                    : p == typeof(float) ? (object)float.Parse(raw, CultureInfo.InvariantCulture)
                    : p == typeof(double) ? (object)double.Parse(raw, CultureInfo.InvariantCulture)
                    : p == typeof(bool) ? (object)bool.Parse(raw)
                    : throw new Exception($"unsupported cue parameter type {p.Name}");
            }
            return values;
        }

        // ------------------------------------------------------------ capture

        private static void Capture()
        {
            ScreenCapture.CaptureScreenshot(Path.Combine(_outDir, $"frame_{_capturedCount:D4}.png"));
            _capturedCount++;
        }

        // ------------------------------------------------------------ finish

        private static void Abort(string why)
        {
            Debug.LogError($"[LookApprove] ABORT: {why}");
            SessionState.SetBool(KeyActive, false);
            // The sentinel is written even here: the caller waits on _DONE.txt, and
            // an abort that never writes it reads exactly like a hung editor.
            WriteSentinel($"ABORT: {why}");
            EditorApplication.Exit(1);
        }

        private static void Finish(string why)
        {
            Debug.Log($"[LookApprove] finishing: {why} ({_capturedCount} frames)");
            SessionState.SetBool(KeyActive, false);
            EditorApplication.update -= Tick;
            WriteSentinel(why);
            EditorApplication.Exit(0);
        }

        private static void WriteSentinel(string why)
        {
            try
            {
                if (string.IsNullOrEmpty(_outDir)) return;
                Directory.CreateDirectory(_outDir);

                // Cues append as they fire; the file's absence is the only honest
                // way to know nothing was staged at all. Never rewrite it here —
                // that would drop declarations made before a domain reload.
                var stagedPath = Path.Combine(_outDir, "_STAGED.txt");
                if (!File.Exists(stagedPath))
                    File.WriteAllText(stagedPath, "nothing staged — the tour ran on the game's own behaviour\n");

                // {"<still label>": <frame index>} — the card maps one still per
                // feature/PR, so these labels ARE the review set's labels.
                File.WriteAllText(Path.Combine(_outDir, "_STILLS.json"),
                    "{\n  " + string.Join(",\n  ", Stills) + "\n}\n");

                File.WriteAllText(Path.Combine(_outDir, "_RUN.json"),
                    "{\n" +
                    $"  \"unity\": \"{Application.unityVersion}\",\n" +
                    $"  \"scene\": \"{Escape(_spec?.scene ?? "")}\",\n" +
                    $"  \"width\": {_spec?.width ?? 0},\n" +
                    $"  \"height\": {_spec?.height ?? 0},\n" +
                    $"  \"fps\": {_spec?.fps ?? 0},\n" +
                    $"  \"frames\": {_capturedCount},\n" +
                    $"  \"seconds\": {(_spec == null || _spec.fps <= 0 ? 0f : _capturedCount / (float)_spec.fps):0.00}\n" +
                    "}\n");

                File.WriteAllText(Path.Combine(_outDir, "_DONE.txt"), $"{why}\nframes={_capturedCount}\n");
            }
            catch { /* best effort — never mask the original reason */ }
        }

        // ------------------------------------------------------------ helpers

        private static string Env(string key, string fallback)
        {
            var v = Environment.GetEnvironmentVariable(key);
            return string.IsNullOrEmpty(v) ? fallback : v;
        }

        private static string Escape(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"");

        /// <summary>Resolve a type by full name, else by bare name across loaded assemblies.</summary>
        private static Type ResolveType(string name)
        {
            if (string.IsNullOrEmpty(name)) return null;
            var direct = Type.GetType(name);
            if (direct != null) return direct;
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                try
                {
                    var t = asm.GetType(name);
                    if (t != null) return t;
                    foreach (var candidate in asm.GetTypes())
                        if (candidate.Name == name) return candidate;
                }
                catch (ReflectionTypeLoadException) { /* partially-loaded assembly — keep looking */ }
            }
            return null;
        }

        // ------------------------------------------------------------ game view

        /// <summary>
        /// Forces a fixed-resolution Game View so the capture size is deterministic
        /// instead of following whatever the window happens to be.
        ///
        /// UNSUPPORTED API — UnityEditor.GameView / GameViewSizes are internal and
        /// have moved between versions. Keep the try/catch: the fallback (a plain
        /// window resize at Free Aspect) still produces a usable tour, and a
        /// hard failure here would cost the whole capture over a framing detail.
        /// </summary>
        private static void ConfigureGameView(int width, int height)
        {
            EditorWindow win = null;
            try
            {
                var asm = typeof(UnityEditor.Editor).Assembly;
                var gameViewType = asm.GetType("UnityEditor.GameView");
                win = EditorWindow.GetWindow(gameViewType, false, "Game", true);

                var sizesType = asm.GetType("UnityEditor.GameViewSizes");
                var singletonType = typeof(ScriptableSingleton<>).MakeGenericType(sizesType);
                var instance = singletonType
                    .GetProperty("instance", BindingFlags.Public | BindingFlags.Static)
                    .GetValue(null);

                var currentGroup = sizesType.GetProperty("currentGroupType").GetValue(instance);
                var group = sizesType.GetMethod("GetGroup").Invoke(instance, new[] { (object)(int)currentGroup });
                var groupType = group.GetType();

                var label = $"LookApprove {width}x{height}";
                var index = IndexOfSize(groupType, group, label);
                if (index < 0)
                {
                    var gvsType = asm.GetType("UnityEditor.GameViewSize");
                    var gvstType = asm.GetType("UnityEditor.GameViewSizeType");
                    var ctor = gvsType.GetConstructor(new[] { gvstType, typeof(int), typeof(int), typeof(string) });
                    var size = ctor.Invoke(new[]
                    {
                        Enum.Parse(gvstType, "FixedResolution"), (object)width, height, label
                    });
                    groupType.GetMethod("AddCustomSize").Invoke(group, new[] { size });
                    index = IndexOfSize(groupType, group, label);
                }

                if (index >= 0)
                {
                    gameViewType.GetMethod("SizeSelectionCallback",
                            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
                        .Invoke(win, new object[] { index, null });
                    Debug.Log($"[LookApprove] game view fixed at {width}x{height} (index {index})");
                }
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[LookApprove] fixed game-view size unavailable ({e.Message}); " +
                                 "falling back to window size / Free Aspect");
            }

            if (win == null) return;
            win.position = new Rect(40f, 60f, width / 2f + 40f, height / 2f + 60f);
            win.Show();
            win.Focus();   // the editor must be HEADED; the window need not stay frontmost
        }

        private static int IndexOfSize(Type groupType, object group, string label)
        {
            var texts = (string[])groupType.GetMethod("GetDisplayTexts").Invoke(group, null);
            for (var i = 0; i < texts.Length; i++)
                if (texts[i].StartsWith(label, StringComparison.Ordinal)) return i;
            return -1;
        }
    }
}
