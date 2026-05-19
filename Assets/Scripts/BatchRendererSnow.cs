using System;
using System.Collections;
using Unity.Collections;
using Unity.Collections.LowLevel.Unsafe;
using Unity.Jobs;
using UnityEngine;
using UnityEngine.Rendering;


using Random = UnityEngine.Random;
// This code uses the example BRG code provided by Unity:
// https://github.com/AlexMerzlikin/Unity-BatchRendererGroup-Boids/blob/master/Assets/Scripts/BatchRendererGroupExample/SimpleBRGExample.cs#L193
public class BRGSnow : MonoBehaviour
{


    // Set this to a suitable Mesh via the Inspector, such as a Cube mesh
    public Mesh mesh;
    // Set this to a suitable Material via the Inspector, such as a default material that
    // uses Universal Render Pipeline/Lit
    public Material material;
    public ComputeShader memcpy;

    public float fallHeight = 5f;

    public float animationDuration = 3f;

    public Color OriginalColor = Color.gray;

    public Color FinalColor = Color.white;

    public float colorAnimTime = 2f;

    public Vector2 windVector = new Vector2(0.2f, 0.1f);

    public float Scale = 0.2f;

    public Vector2 SnowAreaSize = new Vector2(10f, 10f);

    [Range(0f, 50f)]
    [Tooltip("Snow instance scale offset (+-), in % of original scale")]
    public float SnowScaleInstanceOffset = 10f;

    [Range(0f, 180f)]
    [Tooltip("Snow instance rotation offset (+-), in degrees")]
    public float SnowRotationInstanceOffset = 45f;

    private BatchRendererGroup m_BRG;

    private GraphicsBuffer m_InstanceData;
    private GraphicsBuffer m_CopySrc;
    private BatchID m_BatchID;
    private BatchMeshID m_MeshID;
    private BatchMaterialID m_MaterialID;

    // Some helper constants to make calculations later a bit more convenient.
    private const int kSizeOfMatrix = sizeof(float) * 4 * 4;
    private const int kSizeOfPackedMatrix = sizeof(float) * 4 * 3;
    private const int kSizeOfFloat4 = sizeof(float) * 4;
    private const int kBytesPerInstance = (kSizeOfPackedMatrix * 2) + kSizeOfFloat4;
    private const int kExtraBytes = kSizeOfMatrix * 2;

    private const int kNumInstances = kNumRows * kNumRows;

    private const int kNumRows = 75;

    private float[] m_instanceTimes;
    private Vector2[] m_instanceLocationsXZ;
    private Vector2[] m_instanceVelocitiesXZ;

    public Vector2[] layerAccelerations = new Vector2[] { new Vector2(1, 0), new Vector2(-1, 0) };

    private Vector3[] m_upVectors;
    private Vector3[] m_scales;

    private uint byteAddressObjectToWorld;
    private uint byteAddressWorldToObject;
    private uint byteAddressColor;

    private bool UseConstantBuffer => BatchRendererGroup.BufferTarget == BatchBufferTarget.ConstantBuffer;

    // Offset should be divisible by 64, 48 and 16
    // These can be edited to test nonzero GLES buffer offsets.
    private int BufferSize(int bufferCount) => bufferCount * sizeof(int);
    private int BufferOffset => 0;
    private int BufferWindowSize => UseConstantBuffer ? BatchRendererGroup.GetConstantBufferMaxWindowSize() : 0;

    Vector2 step;
    Vector2 middle;

    public IEnumerator RandomizeAccelerationsBig()
    {
        while (true)
        {
            for (int i = 0; i < layerAccelerations.Length; i++)
            {
                var randomAccelStrength = Random.Range(0f, 1f);
                randomAccelStrength = randomAccelStrength * randomAccelStrength * 4f;

                layerAccelerations[i] = (new Vector2(Random.Range(-1f, 1f), Random.Range(-1f, 1f)).normalized) * randomAccelStrength;
            }

            yield return new WaitForSeconds(10f);
        }
    }


    public IEnumerator RandomizeAccelerationsSmall()
    {
        while (true)
        {
            var randomAccel = Random.Range(0, layerAccelerations.Length);

            var randomAccelStrength = Random.Range(0f, 1f);
            randomAccelStrength = randomAccelStrength * randomAccelStrength * 4f;

            layerAccelerations[randomAccel] = (new Vector2(Random.Range(-1f, 1f), Random.Range(-1f, 1f)).normalized) * randomAccelStrength;

            yield return new WaitForSeconds(3f);
        }
    }

    // Unity provided shaders such as Universal Render Pipeline/Lit expect
    // unity_ObjectToWorld and unity_WorldToObject in a special packed 48 byte
    // format when the DOTS_INSTANCING_ON keyword is enabled.
    // This saves both GPU memory and GPU bandwidth.
    // We define a convenience type here so we can easily convert into this format.
    struct PackedMatrix
    {
        public float c0x;
        public float c0y;
        public float c0z;
        public float c1x;
        public float c1y;
        public float c1z;
        public float c2x;
        public float c2y;
        public float c2z;
        public float c3x;
        public float c3y;
        public float c3z;

        public PackedMatrix(Matrix4x4 m)
        {
            c0x = m.m00;
            c0y = m.m10;
            c0z = m.m20;
            c1x = m.m01;
            c1y = m.m11;
            c1z = m.m21;
            c2x = m.m02;
            c2y = m.m12;
            c2z = m.m22;
            c3x = m.m03;
            c3y = m.m13;
            c3z = m.m23;
        }
    }

    private void PrecomputeData()
    {
        m_upVectors = new Vector3[kNumInstances];
        m_scales = new Vector3[kNumInstances];
        for (int i = 0; i < kNumInstances; i++)
        {
            var rotationOffset = Quaternion.Euler(0f, 0f, Random.Range(-SnowRotationInstanceOffset, SnowRotationInstanceOffset));
            m_upVectors[i] = rotationOffset * Vector3.up;
            m_scales[i] = Vector3.one * Scale * (1f + Random.Range(-SnowScaleInstanceOffset, SnowScaleInstanceOffset) / 100f);
        }
    }

    // Raw buffers are allocated in ints, define an utility method to compute the required
    // amount of ints for our data.
    int BufferCountForInstances(int bytesPerInstance, int numInstances, int extraBytes = 0)
    {
        // Round byte counts to int multiples
        bytesPerInstance = (bytesPerInstance + sizeof(int) - 1) / sizeof(int) * sizeof(int);
        extraBytes = (extraBytes + sizeof(int) - 1) / sizeof(int) * sizeof(int);
        int totalBytes = bytesPerInstance * numInstances + extraBytes;
        return totalBytes / sizeof(int);
    }

    // Helper method to step physics analytically
    private void StepParticle(ref Vector2 pos, ref Vector2 vel, float tA, float tB)
    {
        if (layerAccelerations == null || layerAccelerations.Length < 2)
        {
            pos += vel * (tB - tA);
            return;
        }

        int N = layerAccelerations.Length;
        float sA = tA * (N - 1) / animationDuration;
        float sB = tB * (N - 1) / animationDuration;

        while (sA < sB)
        {
            int j = Mathf.FloorToInt(sA);
            if (j >= N - 1) j = N - 2;

            float next_s = Mathf.Min(sB, j + 1f);
            if (j == N - 2) next_s = sB;

            float s_start = sA - j;
            float s_end = next_s - j;

            Vector2 a_j = layerAccelerations[j];
            Vector2 a_j1 = layerAccelerations[j + 1];

            Vector2 a_start = Vector2.Lerp(a_j, a_j1, s_start);
            Vector2 a_end = Vector2.Lerp(a_j, a_j1, s_end);

            float dt = (next_s - sA) * animationDuration / (N - 1);

            pos += vel * dt + (2f * a_start + a_end) * (dt * dt / 6f);
            vel += (a_start + a_end) * 0.5f * dt;

            sA = next_s;
        }
    }

    // During initialization, we will allocate all required objects, and set up our custom instance data.
    // Use OnEnable() instead of Start() so we also get a call when a domain reload happens.
    void OnEnable()
    {
        PrecomputeData();

        StartCoroutine(RandomizeAccelerationsBig());
        StartCoroutine(RandomizeAccelerationsSmall());
        step = SnowAreaSize / kNumRows;
        middle = new Vector2(SnowAreaSize.x, SnowAreaSize.y) / 2f;

        // Create the BatchRendererGroup and register assets
        m_BRG = new BatchRendererGroup(this.OnPerformCulling, IntPtr.Zero);
        m_MeshID = m_BRG.RegisterMesh(mesh);
        m_MaterialID = m_BRG.RegisterMaterial(material);
        
        // Disable backface culling
        material.SetFloat("_Cull", (float)UnityEngine.Rendering.CullMode.Off);

        // Create the buffer that holds our instance data
        var target = GraphicsBuffer.Target.Raw;
        if (SystemInfo.graphicsDeviceType is GraphicsDeviceType.OpenGLCore or GraphicsDeviceType.OpenGLES3)
            target |= GraphicsBuffer.Target.Constant;

        int bufferCount = BufferCountForInstances(kBytesPerInstance, kNumInstances, kExtraBytes);
        m_CopySrc = new GraphicsBuffer(target,
            bufferCount,
            sizeof(int));
        m_InstanceData = new GraphicsBuffer(target,
            BufferSize(bufferCount) / sizeof(int),
            sizeof(int));

        // Place one zero matrix at the start of the instance data buffer, so loads from address 0 will return zero
        var zero = new Matrix4x4[1] { Matrix4x4.zero };

        // Initialize time offsets for each instance
        m_instanceTimes = new float[kNumInstances];
        m_instanceLocationsXZ = new Vector2[kNumInstances];
        m_instanceVelocitiesXZ = new Vector2[kNumInstances];

        for (int i = 0; i < kNumInstances; i++)
        {
            m_instanceTimes[i] = Random.Range(0f, animationDuration); // Unique offset per instance

            int row = i / kNumRows;
            int col = i % kNumRows;
            m_instanceLocationsXZ[i] = new Vector2(row * step.x - middle.x, col * step.y - middle.y);
            m_instanceVelocitiesXZ[i] = Vector2.zero;

            // Fast-forward simulation to initial time so positions align
            StepParticle(ref m_instanceLocationsXZ[i], ref m_instanceVelocitiesXZ[i], 0f, m_instanceTimes[i]);
        }

        // Create transform matrices for our instances
        var matrices = new Matrix4x4[kNumInstances];

        for(int i = 0; i < kNumInstances; i++)
        {
            float t = m_instanceTimes[i];
            float currentY = fallHeight * (1 - t / animationDuration);
            Vector3 position = new Vector3(m_instanceLocationsXZ[i].x, currentY, m_instanceLocationsXZ[i].y);

            Quaternion rot = Quaternion.LookRotation((position + transform.position - Camera.main.transform.position).normalized, m_upVectors[i]);
            matrices[i] = Matrix4x4.TRS(position + transform.position, rot, m_scales[i]);
        }


        // Convert the transform matrices into the packed format expected by the shader
        var objectToWorld = new PackedMatrix[kNumInstances];
        /*{
            new PackedMatrix(matrices[0]),
            new PackedMatrix(matrices[1]),
            new PackedMatrix(matrices[2]),
        };*/

        for(int i = 0; i < kNumInstances; i++)
        {
            objectToWorld[i] = new PackedMatrix(matrices[i]);
        }

        // Also create packed inverse matrices
        var worldToObject = new PackedMatrix[kNumInstances];
        /*{
            new PackedMatrix(matrices[0].inverse),
            new PackedMatrix(matrices[1].inverse),
            new PackedMatrix(matrices[2].inverse),
        };*/

        for(int i = 0; i < kNumInstances; i++)
        {
            worldToObject[i] = new PackedMatrix(matrices[i].inverse);
        }

        // Make all instances have unique colors
        var colors = new Vector4[kNumInstances];
        /*
        {
            new Vector4(1, 0, 0, 1),
            new Vector4(0, 1, 0, 1),
            new Vector4(0, 0, 1, 1),
        };*/

        for(int i = 0; i < kNumInstances; i++)
        {
            colors[i] = new Vector4(OriginalColor.r, OriginalColor.g, OriginalColor.b, OriginalColor.a);
        }

        // In this simple example, the instance data is placed into the buffer like this:
        // Offset | Description
        //      0 | 64 bytes of zeroes, so loads from address 0 return zeroes
        //     64 | 32 uninitialized bytes to make working with SetData easier, otherwise unnecessary
        //     96 | unity_ObjectToWorld, three packed float3x4 matrices
        //    240 | unity_WorldToObject, three packed float3x4 matrices
        //    384 | _BaseColor, three float4s

        // Compute start addresses for the different instanced properties. unity_ObjectToWorld starts
        // at address 96 instead of 64, because the computeBufferStartIndex parameter of SetData
        // is expressed as source array elements, so it is easier to work in multiples of sizeof(PackedMatrix).
        byteAddressObjectToWorld = kSizeOfPackedMatrix * 2;
        byteAddressWorldToObject = byteAddressObjectToWorld + kSizeOfPackedMatrix * kNumInstances;
        byteAddressColor = byteAddressWorldToObject + kSizeOfPackedMatrix * kNumInstances;

        // Upload our instance data to the GraphicsBuffer, from where the shader can load them.
        m_CopySrc.SetData(zero, 0, 0, 1);
        m_CopySrc.SetData(objectToWorld, 0, (int)((byteAddressObjectToWorld + 0) / kSizeOfPackedMatrix), objectToWorld.Length);
        m_CopySrc.SetData(worldToObject, 0, (int)((byteAddressWorldToObject + 0)  / kSizeOfPackedMatrix), worldToObject.Length);
        m_CopySrc.SetData(colors, 0, (int)((byteAddressColor + 0)  / kSizeOfFloat4), colors.Length);

        int dstSize = m_CopySrc.count * m_CopySrc.stride;
        memcpy.SetBuffer(0, "src", m_CopySrc);
        memcpy.SetBuffer(0, "dest", m_InstanceData);
        memcpy.SetInt("dstOffset", BufferOffset);
        memcpy.SetInt("dstSize", dstSize);
        memcpy.Dispatch(0, dstSize / (64 * 4) + 1, 1, 1);

        // Set up metadata values to point to the instance data. Set the most significant bit 0x80000000 in each,
        // which instructs the shader that the data is an array with one value per instance, indexed by the instance index.
        // Any metadata values used by the shader and not set here will be zero. When such a value is used with
        // UNITY_ACCESS_DOTS_INSTANCED_PROP (i.e. without a default), the shader will interpret the
        // 0x00000000 metadata value so that the value will be loaded from the start of the buffer, which is
        // where we uploaded the matrix "zero" to, so such loads are guaranteed to return zero, which is a reasonable
        // default value.
        var metadata = new NativeArray<MetadataValue>(3, Allocator.Temp);
        metadata[0] = new MetadataValue { NameID = Shader.PropertyToID("unity_ObjectToWorld"), Value = 0x80000000 | byteAddressObjectToWorld, };
        metadata[1] = new MetadataValue { NameID = Shader.PropertyToID("unity_WorldToObject"), Value = 0x80000000 | byteAddressWorldToObject, };
        metadata[2] = new MetadataValue { NameID = Shader.PropertyToID("_BaseColor"), Value = 0x80000000 | byteAddressColor, };

        // Finally, create a batch for our instances, and make the batch use the GraphicsBuffer with our
        // instance data, and the metadata values that specify where the properties are. Note that
        // we do not need to pass any batch size here.
        m_BatchID = m_BRG.AddBatch(metadata, m_InstanceData.bufferHandle, (uint)BufferOffset, (uint)BufferWindowSize);
    }

    // We need to dispose our GraphicsBuffer and BatchRendererGroup when our script is no longer used,
    // to avoid leaking anything. Registered Meshes and Materials, and any batches added to the
    // BatchRendererGroup are automatically disposed when disposing the BatchRendererGroup.
    private void OnDisable()
    {
        m_CopySrc.Dispose();
        m_InstanceData.Dispose();
        m_BRG.Dispose();
    }

    void OnValidate()
    {
        step = SnowAreaSize / kNumRows;
        middle = new Vector2(SnowAreaSize.x, SnowAreaSize.y) / 2f;
    }

    // Update instance positions every frame based on time
    private void Update()
    {
        if (m_BRG == null || m_CopySrc == null || m_InstanceData == null)
            return;

        float dt = Time.deltaTime;
        var matrices = new Matrix4x4[kNumInstances];

        for (int i = 0; i < kNumInstances; i++)
        {
            float t_old = m_instanceTimes[i];
            float t_new = t_old + dt;

            if (t_new >= animationDuration)
            {
                StepParticle(ref m_instanceLocationsXZ[i], ref m_instanceVelocitiesXZ[i], t_old, animationDuration);

                int row = i / kNumRows;
                int col = i % kNumRows;
                m_instanceLocationsXZ[i] = new Vector2(row * step.x - middle.x, col * step.y - middle.y);
                m_instanceVelocitiesXZ[i] = Vector2.zero;

                t_new %= animationDuration;
                t_old = 0f;
            }

            StepParticle(ref m_instanceLocationsXZ[i], ref m_instanceVelocitiesXZ[i], t_old, t_new);
            m_instanceTimes[i] = t_new;

            float currentY = fallHeight * (1 - t_new / animationDuration);
            Vector3 position = new Vector3(m_instanceLocationsXZ[i].x, currentY, m_instanceLocationsXZ[i].y);

            Quaternion rot = Quaternion.LookRotation((position + transform.position - Camera.main.transform.position).normalized, m_upVectors[i]);
            matrices[i] = Matrix4x4.TRS(position + transform.position, rot, m_scales[i]);
        }

        // Convert to packed format
        var objectToWorld = new PackedMatrix[kNumInstances];
        var worldToObject = new PackedMatrix[kNumInstances];

        for (int i = 0; i < kNumInstances; i++)
        {
            objectToWorld[i] = new PackedMatrix(matrices[i]);
            worldToObject[i] = new PackedMatrix(matrices[i].inverse);
        }

        // Update colors (can also be time-based if desired)
        var colors = new Vector4[kNumInstances];


        Vector4 originalColorVec = new Vector4(OriginalColor.r, OriginalColor.g, OriginalColor.b, OriginalColor.a);
        Vector4 finalColorVec = new Vector4(FinalColor.r, FinalColor.g, FinalColor.b, FinalColor.a);
        for (int i = 0; i < kNumInstances; i++)
        {
            float t = m_instanceTimes[i];
            float animT = Mathf.Clamp(t / colorAnimTime, 0f, 1f);
            colors[i] = Vector4.Lerp(originalColorVec, finalColorVec, animT);
        }

        // Upload updated data to graphics buffer
        m_CopySrc.SetData(objectToWorld, 0, (int)((byteAddressObjectToWorld + 0) / kSizeOfPackedMatrix), objectToWorld.Length);
        m_CopySrc.SetData(worldToObject, 0, (int)((byteAddressWorldToObject + 0) / kSizeOfPackedMatrix), worldToObject.Length);
        m_CopySrc.SetData(colors, 0, (int)((byteAddressColor + 0) / kSizeOfFloat4), colors.Length);

        // Copy to instance data buffer
        int dstSize = m_CopySrc.count * m_CopySrc.stride;
        memcpy.SetBuffer(0, "src", m_CopySrc);
        memcpy.SetBuffer(0, "dest", m_InstanceData);
        memcpy.SetInt("dstOffset", BufferOffset);
        memcpy.SetInt("dstSize", dstSize);
        memcpy.Dispatch(0, dstSize / (64 * 4) + 1, 1, 1);
    }

    // The callback method called by Unity whenever it visibility culls to determine which
    // objects to draw. This method will output draw commands that describe to Unity what
    // should be drawn for this BatchRendererGroup.
    public unsafe JobHandle OnPerformCulling(
        BatchRendererGroup rendererGroup,
        BatchCullingContext cullingContext,
        BatchCullingOutput cullingOutput,
        IntPtr userContext)
    {
        // UnsafeUtility.Malloc() requires an alignment, so use the largest integer type's alignment
        // which is a reasonable default.
        int alignment = UnsafeUtility.AlignOf<long>();

        // Acquire a pointer to the BatchCullingOutputDrawCommands struct so we can easily
        // modify it directly.
        var drawCommands = (BatchCullingOutputDrawCommands*)cullingOutput.drawCommands.GetUnsafePtr();

        // Allocate memory for the output arrays. In a more complicated implementation the amount of memory
        // allocated could be dynamically calculated based on what we determined to be visible.
        // In this example, we will just assume that all of our instances are visible and allocate
        // memory for each of them. We need the following allocations:
        // - a single draw command (which draws kNumInstances instances)
        // - a single draw range (which covers our single draw command)
        // - kNumInstances visible instance indices.
        // The arrays must always be allocated using Allocator.TempJob.
        drawCommands->drawCommands = (BatchDrawCommand*)UnsafeUtility.Malloc(UnsafeUtility.SizeOf<BatchDrawCommand>(), alignment, Allocator.TempJob);
        drawCommands->drawRanges = (BatchDrawRange*)UnsafeUtility.Malloc(UnsafeUtility.SizeOf<BatchDrawRange>(), alignment, Allocator.TempJob);
        drawCommands->visibleInstances = (int*)UnsafeUtility.Malloc(kNumInstances * sizeof(int), alignment, Allocator.TempJob);
        drawCommands->drawCommandPickingEntityIds = null;

        drawCommands->drawCommandCount = 1;
        drawCommands->drawRangeCount = 1;
        drawCommands->visibleInstanceCount = kNumInstances;

        // Our example does not use depth sorting, so we can leave the instanceSortingPositions as null.
        drawCommands->instanceSortingPositions = null;
        drawCommands->instanceSortingPositionFloatCount = 0;

        // Configure our single draw command to draw kNumInstances instances
        // starting from offset 0 in the array, using the batch, material and mesh
        // IDs that we registered in the OnEnable() method. No special flags are set.
        drawCommands->drawCommands[0].visibleOffset = 0;
        drawCommands->drawCommands[0].visibleCount = kNumInstances;
        drawCommands->drawCommands[0].batchID = m_BatchID;
        drawCommands->drawCommands[0].materialID = m_MaterialID;
        drawCommands->drawCommands[0].meshID = m_MeshID;
        drawCommands->drawCommands[0].submeshIndex = 0;
        drawCommands->drawCommands[0].splitVisibilityMask = 0xff;
        drawCommands->drawCommands[0].flags = 0;
        drawCommands->drawCommands[0].sortingPosition = 0;

        // Configure our single draw range to cover our single draw command which
        // is at offset 0.
        drawCommands->drawRanges[0].drawCommandsBegin = 0;
        drawCommands->drawRanges[0].drawCommandsCount = 1;
        // In this example we don't care about shadows or motion vectors, so we leave everything
        // to the default zero values, except the renderingLayerMask which we have to set to all ones
        // so the instances will be drawn regardless of mask settings when rendering.
        drawCommands->drawRanges[0].filterSettings = new BatchFilterSettings { renderingLayerMask = 0xffffffff, };
        drawCommands->drawRanges[0].drawCommandsType = BatchDrawCommandType.Direct;

        // Finally, write the actual visible instance indices to their array. In a more complicated
        // implementation, this output would depend on what we determined to be visible, but in this example
        // we will just assume that everything is visible.
        for (int i = 0; i < kNumInstances; ++i)
            drawCommands->visibleInstances[i] = i;

        // This simple example does not use jobs, so we can just return an empty JobHandle.
        // Performance sensitive applications are encouraged to use Burst jobs to implement
        // culling and draw command output, in which case we would return a handle here that
        // completes when those jobs have finished.
        return new JobHandle();
    }
}