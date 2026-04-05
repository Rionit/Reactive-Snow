using UnityEngine;

public class AccumulateAddCompute : MonoBehaviour
{
    [Header("Assign in Inspector")]
    [SerializeField] private ComputeShader addShader;
    [SerializeField] private RenderTexture textureA;
    [SerializeField] private RenderTexture textureB; // persistent state buffer
    [SerializeField] private float snowRate; 

    [Header("Run")]
    [SerializeField] private bool runEveryFrame = true;
    [SerializeField] private bool accumulate = true;

    private RenderTexture tempResult;
    private int kernel;

    private static readonly int TexAId = Shader.PropertyToID("_TexA");
    private static readonly int TexBId = Shader.PropertyToID("_TexB");
    private static readonly int ResultId = Shader.PropertyToID("_Result");
    private static readonly int WidthId = Shader.PropertyToID("_Width");
    private static readonly int HeightId = Shader.PropertyToID("_Height");
    private static readonly int DeltaTimeId = Shader.PropertyToID("_DeltaTime");
    private static readonly int SnowRateId = Shader.PropertyToID("_SnowRate");
    private static readonly int AccumulateId = Shader.PropertyToID("_Accumulate");

    private void Awake()
    {
        if (addShader == null || textureA == null || textureB == null)
        {
            Debug.LogError("Assign the compute shader, textureA, and textureB.");
            enabled = false;
            return;
        }

        if (!SystemInfo.supportsComputeShaders)
        {
            Debug.LogError("Compute shaders are not supported on this platform.");
            enabled = false;
            return;
        }

        if (textureA.width != textureB.width || textureA.height != textureB.height)
        {
            Debug.LogError("Texture A and B must have the same dimensions.");
            enabled = false;
            return;
        }

        kernel = addShader.FindKernel("CSMain");

        tempResult = CreateTempLike(textureB);

        // Clear textureB to black on Awake
        ClearTexture(textureB);
    }

    private void OnDestroy()
    {
        // Clear textureB to black on Destroy
        ClearTexture(textureB);

        if (tempResult != null)
        {
            tempResult.Release();
            tempResult = null;
        }
    }

    // For some reason snow rises quicker if Update
    // but fixedUpdate is too slow and shows circles
    // of the ball moving 
    private void Update()
    {
        if (runEveryFrame)
            DispatchOnce();
    }

    [ContextMenu("Dispatch Once")]
    public void DispatchOnce()
    {
        addShader.SetInt(WidthId, textureA.width);
        addShader.SetInt(HeightId, textureA.height);
        addShader.SetFloat(DeltaTimeId, Time.deltaTime);
        addShader.SetFloat(SnowRateId, snowRate);
        addShader.SetBool(AccumulateId, accumulate);

        addShader.SetTexture(kernel, TexAId, textureA);
        addShader.SetTexture(kernel, TexBId, textureB);
        addShader.SetTexture(kernel, ResultId, tempResult);

        int groupsX = Mathf.CeilToInt(textureA.width / 8.0f);
        int groupsY = Mathf.CeilToInt(textureA.height / 8.0f);

        addShader.Dispatch(kernel, groupsX, groupsY, 1);

        // Copy the new result back into the persistent B texture.
        Graphics.CopyTexture(tempResult, textureB);
    }

    private static RenderTexture CreateTempLike(RenderTexture source)
    {
        var desc = source.descriptor;
        desc.enableRandomWrite = true;

        var rt = new RenderTexture(desc);
        rt.Create();
        return rt;
    }
    
    private static void ClearTexture(RenderTexture rt)
    {
        RenderTexture active = RenderTexture.active;
        RenderTexture.active = rt;
        GL.Clear(true, true, Color.black);
        RenderTexture.active = active;
    }
}