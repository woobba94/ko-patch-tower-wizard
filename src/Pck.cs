using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

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
