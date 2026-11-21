@echo off
setlocal DisableDelayedExpansion
set "TWKO_CMD_PATH=%~f0"
set "TWKO_EXPLICIT_GAME=%~1"
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$s=[IO.File]::ReadAllText($env:TWKO_CMD_PATH,[Text.Encoding]::UTF8); $m=[regex]::Match($s,'(?ms)^#===TWKO-POWERSHELL===\r?\n(.*)\z'); if(!$m.Success){exit 2}; & ([scriptblock]::Create($m.Groups[1].Value))"
exit /b %errorlevel%
#===TWKO-POWERSHELL===
$script:Catalog = @'
{
  "tag": "v1.1.0",
  "release_base": "https://github.com/woobba94/ko-patch-tower-wizard/releases/download/v1.1.0/",
  "package": {
    "archive": "tower-wizard-ko-data.zip",
    "archive_sha256": "b474829c3e512495fa104cf3609ec47222d7627a7152f0417c36bfa8613948fe"
  },
  "legacy": {
    "steam_build": 23289626,
    "base_sha256": "283fe09ff8481568e31ca73127d61fac71be2fdff09c159604e5c09048f9e083",
    "patched_sha256": [
      "9d30d86c62d8bd91d11d5cd7f1a8eb2ac9bea6135b9dc0dbee9d5e09b7550229",
      "e18ef596102a416dde92453faf5be54aadd022a03447c86abbefa6447582b312",
      "565fa0e4ab739e1f8453e3094b125b5c3a859754cfa8a92779752b44b623b379",
      "7e34957f0f3c2001948558e6c95d4e9a340d2b8813081c4ceda3b1af9b4b2883"
    ]
  }
}
'@ | ConvertFrom-Json

$script:InstallerSource = @'
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Text;
using System.Web.Script.Serialization;
using System;

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

namespace TowerWizardKorean
{
    // The stock resources are uncompressed, little-endian Godot 4 binary OptimizedTranslation resources.
    internal sealed class OptimizedTranslation
    {
        private const int Rsrc = 0x43525352;
        private const uint FnvPrime = 0x1000193;
        private readonly byte[] source;
        private readonly int bodyStart;
        private readonly int uidOffset;
        private readonly int localeIndex;
        private readonly Dictionary<int, byte[]> properties = new Dictionary<int, byte[]>();
        private readonly List<int> propertyOrder = new List<int>();
        private readonly int bucketIndex;
        private readonly int stringsIndex;
        private readonly int[] hashes;
        private readonly int[] buckets;
        private byte[] strings;

        internal OptimizedTranslation(byte[] data)
        {
            source = data;
            using (var reader = new BinaryReader(new MemoryStream(data, false)))
            {
                Binary.Require(reader.ReadInt32() == Rsrc && reader.ReadInt32() == 0 && reader.ReadInt32() == 0 &&
                    reader.ReadInt32() == 4, "Unsupported Godot binary translation resource.");
                reader.ReadInt32(); // Engine minor version.
                Binary.Require(reader.ReadInt32() == 5 && Binary.CString(reader) == "OptimizedTranslation",
                    "Unsupported translation resource class or version.");
                Binary.Require(reader.ReadInt64() == 0, "Unexpected translation import metadata.");
                int resourceFlags = reader.ReadInt32();
                Binary.Require((resourceFlags & ~3) == 0, "Unsupported translation resource flags.");
                uidOffset = (int)reader.BaseStream.Position;
                reader.ReadUInt64();
                Binary.Read(reader, 11 * 4);
                int count = reader.ReadInt32();
                Binary.Require(count > 0 && count <= 256, "Invalid resource property name table.");
                var names = new string[count];
                for (int i = 0; i < count; i++) names[i] = Binary.CString(reader);
                Binary.Require(reader.ReadInt32() == 0 && reader.ReadInt32() == 1,
                    "Expected one OptimizedTranslation resource without external dependencies.");
                Binary.CString(reader);
                long offset = reader.ReadInt64();
                Binary.Require(offset == reader.BaseStream.Position && Binary.CString(reader) == "OptimizedTranslation",
                    "Invalid translation body offset.");
                bodyStart = (int)reader.BaseStream.Position;
                int propertyCount = reader.ReadInt32();
                Binary.Require(propertyCount > 0 && propertyCount <= count, "Invalid translation property count.");
                for (int i = 0; i < propertyCount; i++)
                {
                    int id = reader.ReadInt32();
                    Binary.Require(id >= 0 && id < count, "Unexpected translation property ID.");
                    int start = (int)reader.BaseStream.Position;
                    int kind = reader.ReadInt32();
                    switch (names[id])
                    {
                        case "hash_table":
                            Binary.Require(kind == 32, "Invalid optimized translation hash table.");
                            hashes = ReadInts(reader);
                            break;
                        case "bucket_table":
                            Binary.Require(kind == 32, "Invalid optimized translation bucket table.");
                            buckets = ReadInts(reader);
                            bucketIndex = id;
                            break;
                        case "strings":
                            Binary.Require(kind == 31, "Invalid optimized translation strings.");
                            strings = Binary.Read(reader, reader.ReadInt32());
                            Binary.Read(reader, Binary.Padding(strings.Length, 4));
                            stringsIndex = id;
                            break;
                        case "locale":
                            Binary.Require(kind == 5 && Binary.CString(reader) == "en", "Expected an English source table.");
                            break;
                        case "script":
                            Binary.Require(kind == 1, "Translation resource includes a script.");
                            break;
                        default:
                            throw new InvalidDataException("Unexpected translation property: " + names[id]);
                    }
                    propertyOrder.Add(id);
                    properties.Add(id, Binary.Slice(data, start, (int)reader.BaseStream.Position - start));
                }
                localeIndex = Array.IndexOf(names, "locale");
                Binary.Require(hashes != null && hashes.Length > 0 && buckets != null && strings != null &&
                    localeIndex >= 0 && reader.ReadInt32() == Rsrc && reader.BaseStream.Position == data.Length,
                    "Incomplete optimized translation.");
            }
        }

        internal int Translate(TranslationRecipe recipe)
        {
            var unkeyed = new Dictionary<Tuple<int, int, int>, Message>();
            var keyed = new Dictionary<int, Message>();
            foreach (Message message in recipe.messages)
            {
                if (!string.IsNullOrEmpty(message.key))
                {
                    int slot = Find(message.key);
                    if (slot >= 0 && Matches(slot, message)) keyed.Add(slot, message);
                }
                else if (recipe.hash_count == hashes.Length)
                {
                    unkeyed.Add(Tuple.Create(message.bucket, message.seed, message.hash), message);
                }
            }

            int english = 0;
            var used = new HashSet<int>();
            using (var output = new MemoryStream())
            {
                for (int bucket = 0; bucket < hashes.Length; bucket++)
                {
                    int start = hashes[bucket];
                    if (start == -1) continue;
                    int end = BucketEnd(start);
                    for (int slot = start + 2; slot < end; slot += 4)
                    {
                        Binary.Require(used.Add(slot), "Duplicate optimized translation slot.");
                        CheckMessage(slot);
                        Message row;
                        var identity = Tuple.Create(bucket, buckets[start + 1], buckets[slot]);
                        if (keyed.TryGetValue(slot, out row) ||
                            (unkeyed.TryGetValue(identity, out row) && Matches(slot, row)))
                        {
                            byte[] translated = Binary.Utf8.GetBytes(row.korean + "\0");
                            buckets[slot + 1] = (int)output.Position;
                            buckets[slot + 2] = translated.Length;
                            buckets[slot + 3] = translated.Length;
                            output.Write(translated, 0, translated.Length);
                        }
                        else
                        {
                            int offset = buckets[slot + 1], size = buckets[slot + 2];
                            buckets[slot + 1] = (int)output.Position;
                            output.Write(strings, offset, size);
                            english++;
                        }
                    }
                }
                strings = output.ToArray();
            }
            return english;
        }

        internal byte[] ToKoreanResource()
        {
            if (!properties.ContainsKey(localeIndex)) propertyOrder.Add(localeIndex);
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write(source, 0, uidOffset);
                writer.Write(-1L);
                writer.Write(source, uidOffset + 8, bodyStart - uidOffset - 8);
                writer.Write(propertyOrder.Count);
                foreach (int id in propertyOrder)
                {
                    writer.Write(id);
                    if (id == localeIndex)
                    {
                        writer.Write(5);
                        Binary.CString(writer, "ko");
                    }
                    else if (id == stringsIndex)
                    {
                        writer.Write(31);
                        writer.Write(strings.Length);
                        writer.Write(strings);
                        writer.Write(new byte[Binary.Padding(strings.Length, 4)]);
                    }
                    else if (id == bucketIndex)
                    {
                        writer.Write(32);
                        writer.Write(buckets.Length);
                        foreach (int num in buckets) writer.Write(num);
                    }
                    else
                    {
                        writer.Write(properties[id]);
                    }
                }
                writer.Write(Rsrc);
                return stream.ToArray();
            }
        }

        private static int[] ReadInts(BinaryReader reader)
        {
            int count = reader.ReadInt32();
            Binary.Require(count >= 0 && count <= (reader.BaseStream.Length - reader.BaseStream.Position) / 4,
                "Invalid translation array length.");
            var result = new int[count];
            for (int i = 0; i < count; i++) result[i] = reader.ReadInt32();
            return result;
        }

        private int BucketEnd(int start)
        {
            Binary.Require(start >= 0 && start <= buckets.Length - 2 && buckets[start] > 0 &&
                buckets[start] <= (buckets.Length - start - 2) / 4, "Invalid optimized translation bucket.");
            return start + 2 + buckets[start] * 4;
        }

        private int Find(string key)
        {
            int index = (int)(Hash(key, 0) % (uint)hashes.Length);
            int start = hashes[index];
            if (start == -1) return -1;
            int end = BucketEnd(start);
            uint wanted = Hash(key, unchecked((uint)buckets[start + 1]));
            for (int slot = start + 2; slot < end; slot += 4)
                if (unchecked((uint)buckets[slot]) == wanted) return slot;
            return -1;
        }

        private bool Matches(int slot, Message row)
        {
            CheckMessage(slot);
            return buckets[slot + 3] == row.raw_size &&
                Binary.Sha256(strings, buckets[slot + 1], buckets[slot + 2]) == row.source_sha256;
        }

        private void CheckMessage(int slot)
        {
            int start = buckets[slot + 1], size = buckets[slot + 2], rawSize = buckets[slot + 3];
            Binary.Require(start >= 0 && size > 0 && start <= strings.Length - size && rawSize >= size,
                "Invalid optimized translation message.");
        }

        private static uint Hash(string key, uint seed)
        {
            uint value = seed == 0 ? FnvPrime : seed;
            foreach (byte element in Binary.Utf8.GetBytes(key))
            {
                // Godot 4.2 hashes UTF-8 bytes through char on the Windows x64 runtime.
                value = unchecked((value * FnvPrime) ^ (uint)(sbyte)element);
            }
            return value;
        }
    }
}

namespace TowerWizardKorean
{
    internal static class Binary
    {
        internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        internal static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidDataException(message);
        }

        internal static byte[] Read(BinaryReader reader, int length)
        {
            Require(length >= 0 && length <= reader.BaseStream.Length - reader.BaseStream.Position,
                "Invalid resource length.");
            return reader.ReadBytes(length);
        }

        internal static string CString(BinaryReader reader)
        {
            byte[] value = Read(reader, reader.ReadInt32());
            Require(value.Length > 0 && value[value.Length - 1] == 0, "Expected a null-terminated string.");
            return Utf8.GetString(value, 0, value.Length - 1);
        }

        internal static void CString(BinaryWriter writer, string value)
        {
            byte[] bytes = Utf8.GetBytes(value);
            writer.Write(bytes.Length + 1);
            writer.Write(bytes);
            writer.Write((byte)0);
        }

        internal static int Padding(long length, int alignment)
        {
            return (int)((alignment - length % alignment) % alignment);
        }

        internal static byte[] Slice(byte[] data, int offset, int length)
        {
            var result = new byte[length];
            Buffer.BlockCopy(data, offset, result, 0, length);
            return result;
        }

        internal static string Sha256(byte[] data, int offset, int length)
        {
            using (var algorithm = SHA256.Create())
                return BitConverter.ToString(algorithm.ComputeHash(data, offset, length)).Replace("-", "").ToLowerInvariant();
        }

        internal static byte[] Md5(byte[] data, int offset, int length)
        {
            using (var algorithm = MD5.Create()) return algorithm.ComputeHash(data, offset, length);
        }
    }

    internal sealed class Pck
    {
        private sealed class Entry
        {
            internal long Offset;
            internal int Size;
            internal byte[] Digest;
        }

        private const int HeaderSize = 140;
        private readonly byte[] data;
        private readonly byte[] key;
        private readonly int baseOffset;
        private readonly Dictionary<string, Entry> entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
        private readonly List<string> paths = new List<string>();

        internal Pck(string path, byte[] pckKey)
        {
            data = File.ReadAllBytes(path);
            key = pckKey;
            Binary.Require(data.Length >= HeaderSize &&
                Encoding.ASCII.GetString(data, 0, 4) == "GDPC" &&
                BitConverter.ToInt32(data, 4) == 2 && BitConverter.ToInt32(data, 8) == 4 &&
                BitConverter.ToInt32(data, 20) == 1, "Unsupported Godot PCK format.");
            long payload = BitConverter.ToInt64(data, 24);
            long directorySize = BitConverter.ToInt64(data, 116);
            int count = BitConverter.ToInt32(data, 96);
            Binary.Require(payload >= HeaderSize && payload <= data.Length &&
                directorySize >= 0 && directorySize <= payload - HeaderSize &&
                directorySize + Binary.Padding(directorySize, 16) <= payload - HeaderSize &&
                count > 0 && count <= directorySize / 44, "Invalid PCK directory bounds.");
            baseOffset = (int)payload;
            int length = (int)directorySize;
            byte[] iv = Binary.Slice(data, 124, 16);
            byte[] directory = Cfb128(Binary.Slice(data, HeaderSize, length + Binary.Padding(length, 16)), iv, false);
            Binary.Require(Binary.Md5(directory, 0, length).SequenceEqual(Binary.Slice(data, 100, 16)),
                "The Godot PCK key did not match this installation.");

            using (var reader = new BinaryReader(new MemoryStream(directory, 0, length, false)))
            {
                for (int i = 0; i < count; i++)
                {
                    int pathLength = reader.ReadInt32();
                    byte[] bytes = Binary.Read(reader, pathLength);
                    string name = Binary.Utf8.GetString(bytes).TrimEnd('\0');
                    long offset = reader.ReadInt64();
                    long size = reader.ReadInt64();
                    byte[] digest = Binary.Read(reader, 16);
                    int flags = reader.ReadInt32();
                    Binary.Require(name.StartsWith("res://", StringComparison.Ordinal) &&
                        name.Length > 6 && name.IndexOf('\0') < 0 && !name.Contains("\\") &&
                        !name.Substring(6).Split('/').Any(segment => segment == "" || segment == "." || segment == "..") &&
                        offset >= 0 && size >= 0 && offset <= data.Length - baseOffset - size && flags == 0,
                        "Unsupported PCK entry: " + name);
                    entries.Add(name, new Entry { Offset = offset, Size = (int)size, Digest = digest });
                    paths.Add(name);
                }
                Binary.Require(reader.BaseStream.Position == length, "Invalid PCK directory size.");
            }
        }

        internal bool HasKoreanPatch
        {
            get { return paths.Any(path => path.StartsWith("res://_tower_wizard_ko/", StringComparison.Ordinal)); }
        }

        internal byte[] Read(string path)
        {
            Entry entry;
            Binary.Require(entries.TryGetValue(path, out entry), "Game resource missing: " + path);
            int start = checked(baseOffset + (int)entry.Offset);
            Binary.Require(Binary.Md5(data, start, entry.Size).SequenceEqual(entry.Digest), "Invalid resource checksum: " + path);
            return Binary.Slice(data, start, entry.Size);
        }

        internal void Write(string target, Dictionary<string, byte[]> replacements)
        {
            var updated = new Dictionary<string, Entry>(entries, StringComparer.Ordinal);
            var resultPaths = new List<string>(paths);
            int payloadSize = data.Length - baseOffset;
            using (var appended = new MemoryStream())
            {
                foreach (string path in replacements.Keys.OrderBy(name => name, StringComparer.Ordinal))
                {
                    byte[] value = replacements[path];
                    byte[] padding = new byte[Binary.Padding(payloadSize + appended.Length, 16)];
                    appended.Write(padding, 0, padding.Length);
                    if (!updated.ContainsKey(path)) resultPaths.Add(path);
                    updated[path] = new Entry {
                        Offset = payloadSize + appended.Length, Size = value.Length, Digest = Binary.Md5(value, 0, value.Length)
                    };
                    appended.Write(value, 0, value.Length);
                }
                byte[] directory = DirectoryBytes(resultPaths, updated);
                byte[] digest = Binary.Md5(directory, 0, directory.Length);
                byte[] iv;
                using (var sha = SHA256.Create()) iv = sha.ComputeHash(directory).Take(16).ToArray();
                byte[] padded = new byte[directory.Length + Binary.Padding(directory.Length, 16)];
                Buffer.BlockCopy(directory, 0, padded, 0, directory.Length);
                byte[] encrypted = Cfb128(padded, iv, true);
                byte[] header = Binary.Slice(data, 0, 96);
                int newBase = HeaderSize + encrypted.Length + Binary.Padding(HeaderSize + encrypted.Length, 16);
                Buffer.BlockCopy(BitConverter.GetBytes((long)newBase), 0, header, 24, 8);

                using (var stream = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var writer = new BinaryWriter(stream))
                {
                    writer.Write(header);
                    writer.Write(resultPaths.Count);
                    writer.Write(digest);
                    writer.Write((long)directory.Length);
                    writer.Write(iv);
                    writer.Write(encrypted);
                    writer.Write(new byte[newBase - HeaderSize - encrypted.Length]);
                    writer.Write(data, baseOffset, payloadSize);
                    appended.WriteTo(stream);
                    writer.Flush();
                    stream.Flush(true);
                }
            }

            var verified = new Pck(target, key);
            Binary.Require(verified.entries.Count == updated.Count && verified.HasKoreanPatch,
                "The resulting PCK directory did not verify.");
            foreach (var item in replacements)
                Binary.Require(verified.Read(item.Key).SequenceEqual(item.Value), "Patched resource did not verify: " + item.Key);
            foreach (string path in paths)
            {
                if (replacements.ContainsKey(path)) continue;
                Entry expected = entries[path], actual = verified.entries[path];
                Binary.Require(expected.Offset == actual.Offset && expected.Size == actual.Size &&
                    expected.Digest.SequenceEqual(actual.Digest), "Unrelated resource changed: " + path);
            }
        }

        private static byte[] DirectoryBytes(List<string> names, Dictionary<string, Entry> directory)
        {
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                foreach (string path in names)
                {
                    byte[] bytes = Binary.Utf8.GetBytes(path);
                    int padding = Binary.Padding(bytes.Length, 4);
                    writer.Write(bytes.Length + padding);
                    writer.Write(bytes);
                    writer.Write(new byte[padding]);
                    Entry entry = directory[path];
                    writer.Write(entry.Offset);
                    writer.Write((long)entry.Size);
                    writer.Write(entry.Digest);
                    writer.Write(0);
                }
                return stream.ToArray();
            }
        }

        // Godot uses AES-CFB with 128-bit segments. .NET Framework's CFB provider uses 8-bit segments.
        private byte[] Cfb128(byte[] bytes, byte[] feedback, bool encrypt)
        {
            var result = new byte[bytes.Length];
            feedback = (byte[])feedback.Clone();
            var mask = new byte[16];
            using (var aes = Aes.Create())
            {
                aes.Mode = CipherMode.ECB;
                aes.Padding = PaddingMode.None;
                aes.Key = key;
                using (var cipher = aes.CreateEncryptor())
                {
                    for (int offset = 0; offset < bytes.Length; offset += 16)
                    {
                        cipher.TransformBlock(feedback, 0, 16, mask, 0);
                        for (int i = 0; i < 16; i++) result[offset + i] = (byte)(bytes[offset + i] ^ mask[i]);
                        Buffer.BlockCopy(encrypt ? result : bytes, offset, feedback, 0, 16);
                    }
                }
            }
            return result;
        }
    }
}
'@

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-VdfField([string]$Vdf, [string]$Name) {
    $pattern = '(?m)^\s*"' + [regex]::Escape($Name) + '"\s*"([^"\r\n]*)"'
    $match = [regex]::Match($Vdf, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-SteamRoots {
    $registry = @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Property = 'SteamPath' }
        @{ Path = 'HKLM:\Software\WOW6432Node\Valve\Steam'; Property = 'InstallPath' }
        @{ Path = 'HKLM:\Software\Valve\Steam'; Property = 'InstallPath' }
    )
    foreach ($entry in $registry) {
        $value = Get-ItemPropertyValue -LiteralPath $entry.Path -Name $entry.Property -ErrorAction SilentlyContinue
        if ($value) { $value }
    }
    $programFiles = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($programFiles) { Join-Path $programFiles 'Steam' }
}

function Find-SteamGames([string[]]$SteamRoots) {
    $libraries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $SteamRoots) {
        if (!(Test-Path -LiteralPath $root -PathType Container)) { continue }
        $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
        [void]$libraries.Add($resolved)
        $vdf = Join-Path $resolved 'steamapps/libraryfolders.vdf'
        if (!(Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        $body = [IO.File]::ReadAllText($vdf, [Text.Encoding]::UTF8)
        # The numeric form is used by older Steam clients.
        foreach ($match in [regex]::Matches($body, '(?m)^\s*"(?:path|\d+)"\s+"([^"\r\n]+)"')) {
            $path = $match.Groups[1].Value.Replace('\\', '\')
            if ([IO.Path]::IsPathRooted($path) -and (Test-Path -LiteralPath $path -PathType Container)) {
                [void]$libraries.Add((Resolve-Path -LiteralPath $path).ProviderPath)
            }
        }
    }
    foreach ($library in $libraries) {
        $appManifest = Join-Path $library 'steamapps/appmanifest_3372980.acf'
        if (!(Test-Path -LiteralPath $appManifest -PathType Leaf)) { continue }
        $body = [IO.File]::ReadAllText($appManifest, [Text.Encoding]::UTF8)
        if ((Get-VdfField $body 'appid') -ne '3372980') { continue }
        $leaf = Get-VdfField $body 'installdir'
        if (!$leaf -or $leaf -in '.', '..' -or $leaf.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { continue }
        $dir = Join-Path (Join-Path $library 'steamapps/common') $leaf
        $build = Get-VdfField $body 'buildid'
        $game = Get-GameLocation $dir $build
        if ($null -ne $game -and $seen.Add($game.Directory)) { $game }
    }
}

function Get-GameLocation([string]$Directory, [string]$SteamBuild) {
    if (!(Test-Path -LiteralPath $Directory -PathType Container)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $Directory).ProviderPath
    $pck = Join-Path $resolved 'Tower Wizard.pck'
    $runtime = Join-Path $resolved 'Tower Wizard.exe'
    if (!(Test-Path -LiteralPath $pck -PathType Leaf) -or !(Test-Path -LiteralPath $runtime -PathType Leaf)) {
        return $null
    }
    if (!$SteamBuild) {
        $steamApps = Split-Path -Parent (Split-Path -Parent $resolved)
        $appManifest = Join-Path $steamApps 'appmanifest_3372980.acf'
        if (Test-Path -LiteralPath $appManifest -PathType Leaf) {
            $SteamBuild = Get-VdfField ([IO.File]::ReadAllText($appManifest, [Text.Encoding]::UTF8)) 'buildid'
        }
    }
    [pscustomobject]@{ Directory = $resolved; Pck = $pck; Runtime = $runtime; SteamBuild = $SteamBuild }
}

function Read-Choice([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        return [Console]::ReadLine()
    }
    return Read-Host $Prompt
}

function Select-Game {
    if ($env:TWKO_EXPLICIT_GAME) {
        $game = Get-GameLocation $env:TWKO_EXPLICIT_GAME ''
        if ($null -eq $game) {
            throw "지정한 폴더에 Tower Wizard.exe와 Tower Wizard.pck가 없습니다. $($env:TWKO_EXPLICIT_GAME)"
        }
        return $game
    }
    $games = @(Find-SteamGames @(Get-SteamRoots))
    if ($games.Count -eq 0) {
        throw 'Steam에서 Tower Wizard 설치 폴더를 찾지 못했습니다. Steam의 설치 파일 찾아보기에서 폴더를 확인해 주세요.'
    }
    if ($games.Count -eq 1) { return $games[0] }
    Write-Host 'Tower Wizard가 설치된 폴더가 여러 곳입니다.'
    for ($i = 0; $i -lt $games.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $games[$i].Directory)
    }
    $selected = 0
    $choice = Read-Choice '설치 폴더 번호'
    if (![int]::TryParse($choice, [ref]$selected) -or $selected -lt 1 -or $selected -gt $games.Count) {
        throw '올바른 설치 폴더 번호를 선택해 주세요.'
    }
    $games[$selected - 1]
}

function Get-PckState($Game) {
    $hash = Get-Sha256 $Game.Pck
    $receipt = $Game.Pck + '.ko-receipt.' + $hash
    $baseHash = $hash
    $status = 'candidate'
    if ([IO.File]::Exists($receipt)) {
        if ([IO.FileInfo]::new($receipt).Length -ne 64) { throw '패치 적용 기록이 손상되었습니다.' }
        $baseHash = [IO.File]::ReadAllText($receipt)
        if ($baseHash -cnotmatch '\A[0-9a-f]{64}\z' -or $baseHash -eq $hash) { throw '패치 적용 기록이 손상되었습니다.' }
        $status = 'patched'
    } elseif ($hash -in $script:Catalog.legacy.patched_sha256) {
        $baseHash = $script:Catalog.legacy.base_sha256
        $status = 'legacy'
    } elseif ($hash -eq $script:Catalog.legacy.base_sha256) {
        $status = 'stock'
    }
    return [pscustomobject]@{
        Status = $status
        CurrentHash = $hash
        BaseHash = $baseHash
        Backup = $Game.Pck + '.ko-original.' + $baseHash.Substring(0, 12)
    }
}

function Assert-GameClosed($Game) {
    $active = @(Get-Process -Name 'Tower Wizard' -ErrorAction SilentlyContinue |
        Where-Object { !$_.Path -or $_.Path -eq $Game.Runtime })
    if ($active.Count -gt 0) { throw 'Tower Wizard를 종료한 뒤 다시 실행해 주세요.' }
}

function Assert-CurrentPck($Game, $State) {
    Assert-GameClosed $Game
    if ((Get-Sha256 $Game.Pck) -ne $State.CurrentHash) {
        throw '진행 중 Steam 설치 파일이 변경되었습니다. 메뉴에서 다시 확인해 주세요.'
    }
}

function New-TempPath([string]$Directory, [string]$Suffix) {
    Join-Path $Directory ('.twko-' + [Guid]::NewGuid().ToString('N') + $Suffix)
}

function Get-VerifiedArchive($Build) {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $cache = Join-Path $local 'ko-patch-tower-wizard/cache'
    [void][IO.Directory]::CreateDirectory($cache)
    $cached = Join-Path $cache ($Build.archive_sha256 + '.zip')
    if ((Test-Path -LiteralPath $cached -PathType Leaf) -and (Get-Sha256 $cached) -eq $Build.archive_sha256) {
        return $cached
    }
    $temporary = New-TempPath $cache '.download'
    $url = $script:Catalog.release_base + $Build.archive
    try {
        Write-Host 'GitHub 릴리스에서 번역 데이터와 갈무리 글꼴을 받는 중입니다.'
        try {
            $curl = Join-Path $env:SystemRoot 'System32/curl.exe'
            if ([IO.File]::Exists($curl)) {
                & $curl --fail --location --silent --show-error --max-redirs 5 --max-time 45 --output $temporary $url
                if ($LASTEXITCODE -ne 0) { throw "curl 종료 코드 $LASTEXITCODE" }
            } else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 45 -OutFile $temporary
            }
        } catch {
            throw "GitHub 릴리스 파일을 받지 못했습니다. $url`n$($_.Exception.Message)"
        }
        if ((Get-Sha256 $temporary) -ne $Build.archive_sha256) {
            throw '다운로드한 ZIP의 SHA-256이 다릅니다. 공식 릴리스의 파일인지 확인해 주세요.'
        }
        try {
            if ([IO.File]::Exists($cached)) {
                [IO.File]::Replace($temporary, $cached, [NullString]::Value)
            } else {
                [IO.File]::Move($temporary, $cached)
            }
        } catch {
            if (!(Test-Path -LiteralPath $cached -PathType Leaf) -or (Get-Sha256 $cached) -ne $Build.archive_sha256) { throw }
        }
        return $cached
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-ZipEntry($Zip, [string]$Name, [long]$Limit) {
    $entry = $Zip.GetEntry($Name)
    if ($null -eq $entry -or $entry.Length -le 0 -or $entry.Length -gt $Limit) {
        throw "배포 ZIP의 필수 데이터가 없거나 비정상입니다. $Name"
    }
    $source = $entry.Open()
    $memory = [IO.MemoryStream]::new()
    try {
        $source.CopyTo($memory)
        if ($memory.Length -ne $entry.Length) { throw "배포 ZIP 항목이 손상되었습니다. $Name" }
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
        $source.Dispose()
    }
}

function Get-Bundle([string]$Path, $Package) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ((Get-Sha256 $Path) -ne $Package.archive_sha256) { throw '검증한 ZIP 파일이 변경되었습니다.' }
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $recipe = Read-ZipEntry $zip 'recipe.json' 4194304
            [void](Read-ZipEntry $zip 'Galmuri-OFL-1.1.txt' 65536)
            [void](Read-ZipEntry $zip 'KeyDot-MIT.txt' 65536)
            return [pscustomobject]@{
                Recipe = [Text.Encoding]::UTF8.GetString($recipe)
                Font9 = Read-ZipEntry $zip 'Galmuri9.res' 4194304
                Font11 = Read-ZipEntry $zip 'Galmuri11.res' 4194304
                Extra = Read-ZipEntry $zip 'extra.ko.translation' 131072
                KeyDot = Read-ZipEntry $zip 'keydot.exe' 1048576
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-GameKey($Game, $Bundle) {
    $temporary = New-TempPath ([IO.Path]::GetTempPath()) '.exe'
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bundle.KeyDot, 0, $Bundle.KeyDot.Length)
        } finally {
            $stream.Dispose()
        }
        $lines = & $temporary $Game.Runtime
        if ($LASTEXITCODE -ne 0) { throw 'KeyDot에서 게임 실행 파일의 PCK 키를 읽지 못했습니다.' }
        $match = [regex]::Match(($lines -join ' '), '\b[a-fA-F0-9]{64}\b')
        if (!$match.Success) { throw '게임 실행 파일의 PCK 키를 찾지 못했습니다.' }
        return $match.Value
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Protect-Original($Game, $State) {
    if (![IO.File]::Exists($State.Backup) -and ($State.Status -in 'stock', 'candidate')) {
        $temporary = New-TempPath $Game.Directory '.backup'
        try {
            [IO.File]::Copy($Game.Pck, $temporary)
            if ((Get-Sha256 $temporary) -ne $State.BaseHash) { throw '백업한 원본 PCK가 예상과 다릅니다.' }
            [IO.File]::Move($temporary, $State.Backup)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    if (![IO.File]::Exists($State.Backup)) {
        throw "원본 백업을 찾을 수 없습니다. $($State.Backup)"
    }
    if ((Get-Sha256 $State.Backup) -ne $State.BaseHash) {
        throw "원본 백업이 손상되었거나 다른 빌드입니다. $($State.Backup)"
    }
}

function Register-Patch($Game, $State, [string]$PatchedHash) {
    $receipt = $Game.Pck + '.ko-receipt.' + $PatchedHash
    if ([IO.File]::Exists($receipt)) {
        if ([IO.File]::ReadAllText($receipt) -cne $State.BaseHash) { throw '동일한 패치의 적용 기록이 현재 백업과 다릅니다.' }
        return
    }
    $temporary = New-TempPath $Game.Directory '.receipt'
    try {
        [IO.File]::WriteAllText($temporary, $State.BaseHash, [Text.Encoding]::ASCII)
        [IO.File]::Move($temporary, $receipt)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-PatchChange($Game, [bool]$Restore) {
    Assert-GameClosed $Game
    $lock = [IO.FileStream]::new($Game.Pck + '.ko-lock', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    $temporary = New-TempPath $Game.Directory '.pck.tmp'
    try {
        $state = Get-PckState $Game
        Write-Host "설치 경로 $($Game.Directory)"
        if ($Game.SteamBuild) { Write-Host "설치된 Steam 빌드 $($Game.SteamBuild)" }
        if ($Restore) {
            if ($state.Status -in 'stock', 'candidate') {
                Write-Host '현재 PCK에 적용 기록이 없어 파일을 그대로 두었습니다.'
                return
            }
            Protect-Original $Game $state
            [IO.File]::Copy($state.Backup, $temporary)
            if ((Get-Sha256 $temporary) -ne $state.BaseHash) { throw '복구용 원본 사본이 손상되었습니다.' }
        } else {
            $archive = Get-VerifiedArchive $script:Catalog.package
            $bundle = Get-Bundle $archive $script:Catalog.package
            Assert-CurrentPck $Game $state
            $original = $Game.Pck
            if ($state.Status -in 'patched', 'legacy') {
                Protect-Original $Game $state
                $original = $state.Backup
            }
            try {
                $key = Get-GameKey $Game $bundle
                if (!('TowerWizardKorean.Installer' -as [type])) {
                    Add-Type -TypeDefinition $script:InstallerSource -ReferencedAssemblies 'System.dll','System.Core.dll','System.Web.Extensions.dll'
                }
                $english = [TowerWizardKorean.Installer]::Build($original, $temporary, $key, $bundle.Recipe,
                    $bundle.Font9, $bundle.Font11, $bundle.Extra)
            } catch {
                $details = $_.Exception.GetBaseException().Message
                throw ("이 설치본에서 번역 리소스의 호환성을 확인하지 못했습니다. 게임 파일은 그대로입니다." +
                    [Environment]::NewLine + "현재 PCK SHA-256 $($state.CurrentHash)" + [Environment]::NewLine + $details)
            }
            Assert-CurrentPck $Game $state
            Protect-Original $Game $state
            Register-Patch $Game $state (Get-Sha256 $temporary)
        }
        Assert-CurrentPck $Game $state
        [IO.File]::Replace($temporary, $Game.Pck, [NullString]::Value)
        if ($Restore) {
            Write-Host '원본 PCK를 복구했습니다.' -ForegroundColor Green
        } else {
            Write-Host '한국어 패치를 적용했습니다. Steam에서 게임을 실행하면 됩니다.' -ForegroundColor Green
            if ($english -gt 0) {
                Write-Host "원문이 달라졌거나 번역을 확인할 수 없는 ${english}개 항목은 영어로 표시합니다."
            }
        }
        Write-Host "원본 백업 $($state.Backup)"
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        $lock.Dispose()
    }
}

function Show-Compatibility {
    Write-Host 'Steam 빌드 번호와 관계없이 설치 과정에서 번역 리소스의 호환성을 확인합니다.'
    Write-Host "실행 검증을 마친 Steam 빌드 $($script:Catalog.legacy.steam_build)"
    $games = if ($env:TWKO_EXPLICIT_GAME) { Get-GameLocation $env:TWKO_EXPLICIT_GAME '' } else { Find-SteamGames @(Get-SteamRoots) }
    foreach ($game in $games) {
        Write-Host "감지된 설치 경로 $($game.Directory)"
        if ($game.SteamBuild) { Write-Host "설치된 Steam 빌드 $($game.SteamBuild)" }
        try {
            $state = Get-PckState $game
            $labels = @{ stock = '검증된 원본'; patched = '한국어 적용됨'; legacy = '이전 한국어 패치 적용됨'; candidate = '한국어 적용 시 호환성을 확인합니다.' }
            Write-Host "  $($labels[$state.Status])"
            Write-Host "  현재 PCK SHA-256 $($state.CurrentHash)"
        } catch {
            Write-Host $_.Exception.Message
        }
    }
}

function Invoke-Menu {
    $exitCode = 0
    while ($true) {
        Write-Host "`nTower Wizard 비공식 한국어 패치 $($script:Catalog.tag)"
        Write-Host '1. 한국어 적용 / 재설치'
        Write-Host '2. 원본 복구'
        Write-Host '3. 설치 상태 확인'
        Write-Host '0. 종료'
        $choice = Read-Choice '번호 선택'
        if ($null -eq $choice -or $choice.Trim() -eq '0') { return $exitCode }
        switch ($choice.Trim()) {
            '3' { Show-Compatibility }
            { $_ -in '1', '2' } {
                try {
                    $game = Select-Game
                    Invoke-PatchChange $game ($_ -eq '2')
                    $exitCode = 0
                } catch {
                    Write-Host ('오류: ' + $_.Exception.Message) -ForegroundColor Red
                    $exitCode = 1
                }
            }
            default { Write-Host '0~3 중 하나를 선택해 주세요.' }
        }
    }
}

exit (Invoke-Menu)
