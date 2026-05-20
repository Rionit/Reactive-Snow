using System;
using UnityEngine;
using UnityEngine.Serialization;
using UnityEngine.InputSystem;

public class SnowController : MonoBehaviour
{
    [Header("Assign in Inspector")]
    [SerializeField] private ComputeShader addShader;
    [SerializeField] private RenderTexture objectTex; // object depth map
    [SerializeField] private RenderTexture groundTex; // ground depth map
    [SerializeField] private RenderTexture accumulatedTex; // accumulated state buffer
    [SerializeField] private Camera snowCam;
    [SerializeField] private float snowflakeHeight = 1.0f;
    [SerializeField] [Range(0.0f, 1.0f)] private float snowflakeChance = 0.1f;
    [SerializeField] private GameObject cylinderPrefab;
    [SerializeField] private Camera spawnCamera;
    [SerializeField] private BRGSnow brgsnow;
    [SerializeField] private GameObject textureVisualisations;
    
    [Header("Run")]
    [SerializeField] private bool runEveryFrame = true;
    [SerializeField] private bool accumulate = true;

    private RenderTexture tempResult;
    private int kernel;

    private static readonly int ObjectTexId = Shader.PropertyToID("_ObjectTex");
    private static readonly int GroundTexId = Shader.PropertyToID("_GroundTex");
    private static readonly int AccumulatedTexId = Shader.PropertyToID("_AccumulatedTex");
    private static readonly int ResultId = Shader.PropertyToID("_Result");

    private static readonly int WidthId = Shader.PropertyToID("_Width");
    private static readonly int HeightId = Shader.PropertyToID("_Height");
    private static readonly int DeltaTimeId = Shader.PropertyToID("_DeltaTime");
    private static readonly int SnowflakeHeightId = Shader.PropertyToID("_SnowflakeHeight");
    private static readonly int SnowflakeChanceId = Shader.PropertyToID("_SnowflakeChance");
    private static readonly int AccumulateId = Shader.PropertyToID("_Accumulate");

    // compute shader world mapping
    private static readonly int CameraGlobalOffsetId = Shader.PropertyToID("_CameraGlobalOffset");
    private static readonly int CameraSizeId = Shader.PropertyToID("_CameraSize");

    private Vector3 lastCamPos;

    private void Awake()
    {
        if (addShader == null || objectTex == null || accumulatedTex == null || groundTex == null)
        {
            Debug.LogError("Assign the compute shader, textureA, textureB, and groundTex.");
            enabled = false;
            return;
        }

        if (!SystemInfo.supportsComputeShaders)
        {
            Debug.LogError("Compute shaders are not supported on this platform.");
            enabled = false;
            return;
        }

        if (objectTex.width != accumulatedTex.width || objectTex.height != accumulatedTex.height)
        {
            Debug.LogError("Texture A and B must have the same dimensions.");
            enabled = false;
            return;
        }

        kernel = addShader.FindKernel("CSMain");
        tempResult = CreateTempLike(accumulatedTex);
        ClearTexture(accumulatedTex);
    }

    private void Start()
    {
        Shader.SetGlobalFloat("_SnowCamSize", snowCam.orthographicSize);
        lastCamPos = snowCam.transform.position;
    }

    private void OnDestroy()
    {
        ClearTexture(accumulatedTex);

        if (tempResult != null)
        {
            tempResult.Release();
            tempResult = null;
        }
    }

    private void Update()
    {
        if (runEveryFrame)
            DispatchOnce();

        brgsnow.enabled = accumulate;
        
        if (Keyboard.current.eKey.wasPressedThisFrame)
        {
            Ray ray = spawnCamera.ViewportPointToRay(new Vector3(0.5f, 0.5f, 0f));

            if (Physics.Raycast(ray, out RaycastHit hit, 100f, LayerMask.GetMask("Default")))
            {
                Vector3 spawnPos = hit.point + hit.normal * 1f;

                // Make cylinder lie flat against the surface
                Quaternion rotation =
                    Quaternion.FromToRotation(Vector3.up, hit.normal) *
                    Quaternion.Euler(0f, 0f, 90f);

                Instantiate(cylinderPrefab, spawnPos, rotation);
            }
        }

        if (Keyboard.current.qKey.wasPressedThisFrame)
        {
            textureVisualisations.SetActive(!textureVisualisations.activeSelf);
        }

        if (Keyboard.current.fKey.wasPressedThisFrame)
        {
            accumulate = !accumulate;
        }
    }

    private void LateUpdate()
    {
        Shader.SetGlobalVector("_SnowCamPos", snowCam.transform.position);
    }

    [ContextMenu("Dispatch Once")]
    public void DispatchOnce()
    {
        addShader.SetInt(WidthId, objectTex.width);
        addShader.SetInt(HeightId, objectTex.height);
        addShader.SetFloat(DeltaTimeId, Time.deltaTime);
        addShader.SetFloat(SnowflakeHeightId, snowflakeHeight);
        addShader.SetFloat(SnowflakeChanceId, snowflakeChance);
        addShader.SetBool(AccumulateId, accumulate);

        Vector3 camPos = snowCam.transform.position;
        Vector2 cameraGlobalOffset = new Vector2(camPos.x - lastCamPos.x, camPos.z - lastCamPos.z);
        lastCamPos = camPos;

        float cameraSize = snowCam.orthographicSize * 2.0f;

        addShader.SetVector(CameraGlobalOffsetId, cameraGlobalOffset);
        addShader.SetFloat(CameraSizeId, cameraSize);

        addShader.SetTexture(kernel, ObjectTexId, objectTex);
        addShader.SetTexture(kernel, GroundTexId, groundTex);
        addShader.SetTexture(kernel, AccumulatedTexId, accumulatedTex);
        addShader.SetTexture(kernel, ResultId, tempResult);

        int groupsX = Mathf.CeilToInt(objectTex.width / 8.0f);
        int groupsY = Mathf.CeilToInt(objectTex.height / 8.0f);

        addShader.Dispatch(kernel, groupsX, groupsY, 1);

        Graphics.CopyTexture(tempResult, accumulatedTex);
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