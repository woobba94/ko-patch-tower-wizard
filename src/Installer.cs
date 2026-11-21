using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace TowerWizardKorean
{
    public sealed class ScriptEdit
    {
        public int line_count { get; set; }
        public string original_sha256 { get; set; }
        public string replacement { get; set; }
    }

    public sealed class ScriptRecipe
    {
        public string path { get; set; }
        public ScriptEdit[] edits { get; set; }
    }

    public sealed class Message
    {
        public string key { get; set; }
        public int bucket { get; set; }
        public int seed { get; set; }
        public int hash { get; set; }
        public int raw_size { get; set; }
        public string source_sha256 { get; set; }
        public string korean { get; set; }
    }

    public sealed class TranslationRecipe
    {
        public string path { get; set; }
        public int hash_count { get; set; }
        public Message[] messages { get; set; }
    }

    public sealed class Recipe
    {
        public int schema { get; set; }
        public ScriptRecipe[] scripts { get; set; }
        public TranslationRecipe[] translations { get; set; }
    }

    public static class Installer
    {
        private const string Prefix = "res://_tower_wizard_ko/";
        private const string LocalizationSetting = "internationalization/locale/translations";
        private static readonly string[] AssetNames = { "Galmuri9.res", "Galmuri11.res", "extra.ko.translation" };

        public static bool HasPatch(string path, string hexKey)
        {
            return OpenPack(path, hexKey).HasKoreanPatch;
        }

        public static int Build(string stock, string target, string hexKey, string recipeJson,
            byte[] font9, byte[] font11, byte[] extras)
        {
            var pack = OpenPack(stock, hexKey);
            Binary.Require(!pack.HasKoreanPatch, "The original PCK already contains Korean patch resources.");
            var serializer = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
            var recipe = serializer.Deserialize<Recipe>(recipeJson);
            Binary.Require(recipe.schema == 3, "Unsupported Korean patch data format.");

            var replacements = new Dictionary<string, byte[]>(StringComparer.Ordinal);
            foreach (ScriptRecipe script in recipe.scripts)
                replacements.Add(script.path, ApplyEdits(pack.Read(script.path), script));

            byte[][] assets = { font9, font11, extras };
            for (int i = 0; i < assets.Length; i++) replacements.Add(Prefix + AssetNames[i], assets[i]);

            int english = 0;
            foreach (TranslationRecipe table in recipe.translations)
            {
                var translation = new OptimizedTranslation(pack.Read(table.path));
                english += translation.Translate(table);
                string name = table.path.Substring("res://".Length);
                replacements.Add(Prefix + name.Replace(".en.", ".ko."), translation.ToKoreanResource());
            }

            var translated = replacements.Keys.Where(path => path.EndsWith(".translation", StringComparison.Ordinal)).OrderBy(path => path, StringComparer.Ordinal).ToArray();
            replacements.Add("res://project.binary", AddTranslations(pack.Read("res://project.binary"),
                recipe.translations.Select(item => item.path).ToArray(), translated));
            pack.Write(target, replacements);
            return english;
        }

        private static Pck OpenPack(string path, string hexKey)
        {
            Binary.Require(hexKey.Length == 64, "Invalid PCK key length.");
            var key = new byte[32];
            for (int i = 0; i < key.Length; i++) key[i] = Convert.ToByte(hexKey.Substring(i * 2, 2), 16);
            return new Pck(path, key);
        }

        private static byte[] ApplyEdits(byte[] source, ScriptRecipe recipe)
        {
            string text = Binary.Utf8.GetString(source);
            if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
            var lines = Regex.Matches(text.Replace("\r\n", "\n"), @"[^\n]*\n|[^\n]+$")
                .Cast<Match>().Select(match => match.Value).ToArray();
            var edits = new SortedDictionary<int, ScriptEdit>();
            foreach (ScriptEdit edit in recipe.edits)
            {
                int hit = -1;
                for (int start = 0; start <= lines.Length - edit.line_count; start++)
                {
                    byte[] candidate = Binary.Utf8.GetBytes(string.Concat(lines.Skip(start).Take(edit.line_count)));
                    if (Binary.Sha256(candidate, 0, candidate.Length) != edit.original_sha256) continue;
                    Binary.Require(hit < 0, "Ambiguous localization edit in " + recipe.path);
                    hit = start;
                }
                Binary.Require(hit >= 0, "The localization script changed: " + recipe.path);
                edits.Add(hit, edit);
            }
            var output = new System.Text.StringBuilder(text.Length);
            int position = 0;
            foreach (var edit in edits)
            {
                Binary.Require(edit.Key >= position, "Overlapping localization edits in " + recipe.path);
                while (position < edit.Key) output.Append(lines[position++]);
                output.Append(edit.Value.replacement);
                position += edit.Value.line_count;
            }
            while (position < lines.Length) output.Append(lines[position++]);
            return Binary.Utf8.GetBytes(output.ToString());
        }

        private static byte[] AddTranslations(byte[] data, string[] source, string[] korean)
        {
            using (var reader = new BinaryReader(new MemoryStream(data, false)))
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                int magic = reader.ReadInt32(), count = reader.ReadInt32();
                Binary.Require(magic == 0x47464345 && count > 0 && count < data.Length / 8,
                    "Unsupported project.binary format.");
                writer.Write(magic);
                writer.Write(count);
                bool found = false;
                for (int i = 0; i < count; i++)
                {
                    byte[] name = Binary.Read(reader, reader.ReadInt32());
                    byte[] value = Binary.Read(reader, reader.ReadInt32());
                    if (Binary.Utf8.GetString(name) == LocalizationSetting)
                    {
                        Binary.Require(!found, "Duplicate Godot localization setting.");
                        found = true;
                        value = AddPaths(value, source, korean);
                    }
                    writer.Write(name.Length);
                    writer.Write(name);
                    writer.Write(value.Length);
                    writer.Write(value);
                }
                Binary.Require(found && reader.BaseStream.Position == data.Length,
                    "The game localization settings changed.");
                return stream.ToArray();
            }
        }

        private static byte[] AddPaths(byte[] value, string[] source, string[] korean)
        {
            using (var reader = new BinaryReader(new MemoryStream(value, false)))
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                int kind = reader.ReadInt32(), count = reader.ReadInt32();
                Binary.Require(kind == 34 && count >= 0 && count < value.Length / 4, "Invalid Godot language list.");
                var paths = new HashSet<string>(StringComparer.Ordinal);
                for (int i = 0; i < count; i++)
                {
                    long start = reader.BaseStream.Position;
                    paths.Add(Binary.CString(reader));
                    reader.BaseStream.Position += Binary.Padding(reader.BaseStream.Position - start, 4);
                }
                Binary.Require(reader.BaseStream.Position == value.Length && source.All(paths.Contains) &&
                    !paths.Any(path => path.StartsWith(Prefix, StringComparison.Ordinal) ||
                        Regex.IsMatch(path, @"[._]ko([_-][A-Z]{2})?\.translation$", RegexOptions.IgnoreCase)),
                    "The game has a different translation list or already includes Korean.");
                writer.Write(kind);
                writer.Write(count + korean.Length);
                writer.Write(value, 8, value.Length - 8);
                foreach (string path in korean)
                {
                    long start = stream.Position;
                    Binary.CString(writer, path);
                    writer.Write(new byte[Binary.Padding(stream.Position - start, 4)]);
                }
                return stream.ToArray();
            }
        }
    }
}
