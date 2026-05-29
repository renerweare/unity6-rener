using UnityEngine;

/// <summary>
/// 鼠标点击任意带 BurnController 的 3D 物体来点燃它。
/// 挂到主摄像机上。
/// </summary>
public class MouseClickIgniter : MonoBehaviour
{
    public Camera targetCamera;
    public float maxDistance = 100f;
    public LayerMask layerMask = ~0;

    private void Start()
    {
        if (targetCamera == null)
            targetCamera = Camera.main;
    }

    private void Update()
    {
        if (!Input.GetMouseButtonDown(0))
            return;

        if (targetCamera == null)
            return;

        Ray ray = targetCamera.ScreenPointToRay(Input.mousePosition);

        if (!Physics.Raycast(ray, out RaycastHit hit, maxDistance, layerMask))
            return;

        var burnCtrl = hit.collider.GetComponentInParent<BurnController>();
        if (burnCtrl == null)
            return;

        burnCtrl.Ignite(hit);
    }
}
