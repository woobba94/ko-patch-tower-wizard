using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

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
