using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Madi;

/// <summary>
/// 비밀(LLM 키)을 Windows 자격 증명 관리자에 둔다 — macOS판의 키체인 자리(<c>KeychainSecretStore</c>). 이 사용자만 읽고, 로밍하지 않는다
/// (<c>CRED_PERSIST_LOCAL_MACHINE</c> — 이 PC의 이 사용자). 설정 파일에는 키를 적지 않는다.
/// 이름은 <c>Madi/&lt;이름&gt;</c>(자격 증명 관리자 ▸ Windows 자격 증명 ▸ 일반 자격 증명에 보인다 — 사람이 지울 수 있다).
/// </summary>
public static class CredentialStore
{
    private const int GenericType = 1;
    private const int PersistLocalMachine = 2;
    private const int NotFound = 1168;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    // DllImport(LibraryImport가 아니라) — 생성기가 unsafe 코드를 요구하지 않게. 다루는 값은 모두 IntPtr · 정수(그대로 넘긴다).
    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr buffer);

    private static string Target(string name) => $"Madi/{name}";

    public static void Write(string name, string secret)
    {
        var blob = Encoding.UTF8.GetBytes(secret);
        var target = Marshal.StringToCoTaskMemUni(Target(name));
        var user = Marshal.StringToCoTaskMemUni(Environment.UserName);
        var data = Marshal.AllocCoTaskMem(Math.Max(blob.Length, 1));
        try
        {
            Marshal.Copy(blob, 0, data, blob.Length);
            var credential = new Credential
            {
                Type = GenericType,
                TargetName = target,
                CredentialBlobSize = blob.Length,
                CredentialBlob = data,
                Persist = PersistLocalMachine,
                UserName = user,
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally
        {
            Array.Clear(blob);
            // 놓기 전에 지운다 — 키가 해제된 메모리에 남지 않게.
            Marshal.Copy(new byte[Math.Max(blob.Length, 1)], 0, data, Math.Max(blob.Length, 1));
            Marshal.FreeCoTaskMem(data);
            Marshal.FreeCoTaskMem(target);
            Marshal.FreeCoTaskMem(user);
        }
    }

    public static string? Read(string name)
    {
        if (!CredRead(Target(name), GenericType, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == NotFound) return null;
            throw new Win32Exception(error);
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlobSize == 0) return "";
            var blob = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, blob, 0, blob.Length);
            var secret = Encoding.UTF8.GetString(blob);
            Array.Clear(blob);
            return secret;
        }
        finally
        {
            CredFree(pointer);
        }
    }

    /// <summary>지운다. 없던 것이면 false.</summary>
    public static bool Delete(string name)
    {
        if (CredDelete(Target(name), GenericType, 0)) return true;
        var error = Marshal.GetLastWin32Error();
        return error == NotFound ? false : throw new Win32Exception(error);
    }
}
